"""uv run prepare-release [--dry-run]: opens the pull requests preparing the next gyc release.

One per repository:
  - yruntime: a branch declaring the midgard that gyc bundles, built with that gyc;
  - gymir:    YMIR_VERSION releasing that gyc and bundling the yruntime branch above;
  - CD_suite: the bootstrap chain stages of the gyc releases it does not list yet.
Bootstrap is the source of truth: what is released and what compiles it are read from its default
branch, then every value is asked with that as default. Its YMIR_VERSION can first be edited here:
a change opens a bootstrap pull request and stops, to run again once it is merged.
Everything happens in fresh clones in a temporary directory, removed on exit, so no local checkout
is read or written. --dry-run prints the commits and pushes nothing.
"""

import argparse
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from ymir_dev import cd_suite_stages as stages
from ymir_dev.cd_suite_stages import SEMVER, key
from ymir_dev.common import die

GYLLIR_REPO = "https://github.com/GNU-Ymir/Gyllir.git"
YES_NO = re.compile(r"^[yn]$")


def warn(msg: str) -> None:
    print(f"\033[1;33mwarning:\033[0m {msg}", file=sys.stderr)


def ask(tty, question: str, default: str, pattern: re.Pattern | None = SEMVER) -> str:
    """Reads the terminal until the answer matches pattern."""
    while True:
        answer = stages.ask(tty, question, default)
        if pattern is None or pattern.match(answer):
            return answer
        print(f"  expected {pattern.pattern}", file=sys.stderr)


def git(cwd: Path, *args: str) -> str:
    result = subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True)
    if result.returncode != 0:
        die(f"`git {' '.join(args)}` in {cwd}: {result.stderr.strip()}")
    return result.stdout


class Repo:
    """A blobless clone of a GNU-Ymir repository: every commit, tree and tag, and only the file
    contents actually read."""

    def __init__(self, work: Path, name: str):
        self.name = name
        self.path = work / name
        self.slug = f"GNU-Ymir/{name}"
        git(work, "clone", "--quiet", "--filter=blob:none", f"git@github.com:{self.slug}.git", name)
        head = subprocess.run(["git", "-C", str(self.path), "symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
                              capture_output=True, text=True).stdout.strip()
        self.default = head.removeprefix("origin/") or "master"
        self.releases = stages.releases(str(self.path))

    def git(self, *args: str) -> str:
        return git(self.path, *args)

    def at_default(self, path: str) -> str:
        return self.git("show", f"origin/{self.default}:{path}")

    def has_branch(self, branch: str) -> bool:
        return subprocess.run(["git", "-C", str(self.path), "ls-remote", "--exit-code", "--heads", "origin", branch],
                              capture_output=True).returncode == 0

    def dirty(self) -> bool:
        return bool(self.git("status", "--porcelain", "--untracked-files=no"))

    def has_commits(self) -> bool:
        return bool(self.git("rev-list", f"origin/{self.default}..HEAD").strip())

    def commit(self, message: str) -> None:
        self.git("commit", "--quiet", "-am", message)

    def show(self, branch: str) -> None:
        if not self.has_commits():
            return
        print(f"\n=============== {self.name}: {branch}", flush=True)
        subprocess.run(["git", "-C", str(self.path), "--no-pager", "log", "--reverse", "-p", "--format=--- %s",
                        f"origin/{self.default}..HEAD"])

    def open_pr(self, branch: str, title: str, body: str) -> str:
        """Pushes HEAD as branch, returns the pull request's url."""
        self.git("push", "--quiet", "origin", f"HEAD:refs/heads/{branch}")
        result = subprocess.run(["gh", "pr", "create", "--repo", self.slug, "--base", self.default,
                                 "--head", branch, "--title", title, "--body", body],
                                stdout=subprocess.PIPE, text=True)
        if result.returncode != 0:
            die(f"could not open the pull request of {self.slug}'s {branch}, pushed")
        url = result.stdout.strip()
        print(f"{self.name}: {url}")
        return url


def setting(text: str, name: str) -> str:
    """The value of a YMIR_VERSION setting, empty when it has none."""
    values = re.findall(rf"^{name}=(.*)$", text, re.M)
    return values[-1].strip() if values else ""


def set_setting(path: Path, name: str, value: str) -> None:
    text = path.read_text()
    if not re.search(rf"^{name}=", text, re.M):
        die(f"{path} has no {name}")
    path.write_text(re.sub(rf"^{name}=.*$", lambda _: f"{name}={value}", text, flags=re.M))


def package_version(toml: str) -> str:
    """The package's own `version`: the one above the first [table] header."""
    for line in toml.splitlines():
        if re.match(r"^\s*\[", line):
            break
        if m := re.match(r'^\s*version\s*=\s*"([^"]+)"', line):
            return m.group(1)
    return ""


def set_package_version(toml: str, version: str) -> str:
    lines = toml.splitlines(keepends=True)
    for i, line in enumerate(lines):
        if re.match(r"^\s*\[", line):
            break
        if re.match(r"^\s*version\s*=", line):
            lines[i] = re.sub(r'"[^"]*"', f'"{version}"', line, count=1)
            break
    return "".join(lines)


def std_version(toml: str) -> str:
    """The `version` of the [std] table."""
    section = None
    for line in toml.splitlines():
        if m := re.match(r"^\[(.+)\]", line):
            section = m.group(1)
        elif section == "std" and (m := re.match(r'^version\s*=\s*"([^"]+)"', line)):
            return m.group(1)
    return ""


def next_minor(version: str) -> str:
    major, minor = key(version)[:2]
    return f"{major}.{minor + 1}.0"


def human_join(items: list[str]) -> str:
    """a | a and b | a, b and c"""
    return items[0] if len(items) == 1 else f"{', '.join(items[:-1])} and {items[-1]}"


# ---------------------------------------------------------------------------------------------
# Bootstrap's YMIR_VERSION
# ---------------------------------------------------------------------------------------------

def version_errors(text: str, gymir: Repo, yruntime: Repo) -> list[str]:
    """What an edited bootstrap YMIR_VERSION gets wrong."""
    errors = []
    for name in ("YMIR_BOOTSTRAP_VERSION", "GCC_VERSION", "GYLLIR_VERSION", "MIDGARD_VERSION"):
        if not SEMVER.match(value := setting(text, name)):
            errors.append(f"{name}={value} is not a version")
    compiler, midgard = setting(text, "YMIR_BOOTSTRAP_VERSION"), setting(text, "MIDGARD_VERSION")
    if SEMVER.match(compiler) and compiler not in gymir.releases:
        errors.append(f"gymir has no release {compiler}")
    if SEMVER.match(midgard) and midgard not in yruntime.releases:
        errors.append(f"yruntime has no tag {midgard}")
    return errors


def bump_bootstrap(tty, dry_run: bool, bootstrap: Repo, gymir: Repo, yruntime: Repo) -> bool:
    """Offers to edit bootstrap's YMIR_VERSION. When it changes, opens its pull request and returns
    True: the release is prepared from bootstrap's default branch, once that is merged."""
    if ask(tty, "Edit bootstrap's YMIR_VERSION first? (y/n)", "n", YES_NO) != "y":
        return False
    path = bootstrap.path / "YMIR_VERSION"
    editor = shlex.split(os.environ.get("VISUAL") or os.environ.get("EDITOR") or "vim")
    while True:
        with open("/dev/tty", "w") as out:
            subprocess.run([*editor, str(path)], stdin=tty, stdout=out)
        errors = version_errors(path.read_text(), gymir, yruntime)
        if not errors:
            break
        print("\n".join(f"  {e}" for e in errors), file=sys.stderr)
        print("Press enter to edit it again, ctrl-c to abort. ", end="", file=sys.stderr, flush=True)
        tty.readline()
    if not bootstrap.dirty():
        return False

    old, new = bootstrap.at_default("YMIR_VERSION"), path.read_text()
    bumps = [f"{name} {setting(old, name) or '(unset)'} -> {setting(new, name)}"
             for name in re.findall(r"^([A-Z_]+)=", new, re.M) if setting(old, name) != setting(new, name)]
    message = f"bump {human_join(bumps)}" if bumps else "update YMIR_VERSION"

    print("\n=============== bootstrap", flush=True)
    subprocess.run(["git", "-C", str(bootstrap.path), "--no-pager", "diff"])
    print()
    if dry_run:
        print(f"Dry run: nothing pushed. The release is prepared from bootstrap's {bootstrap.default} "
              "once this change is on it.")
        return True

    ymi_key = ask(tty, "bootstrap work item", "", re.compile(r"^YMI-\d+$"))
    compiler = setting(new, "YMIR_BOOTSTRAP_VERSION")
    if compiler != setting(old, "YMIR_BOOTSTRAP_VERSION"):
        major, minor = key(compiler)[:2]
        branch, title = f"{ymi_key}-compile-from-{major}.{minor}", f"[{ymi_key}][chore] Update to ymir {compiler}"
    else:
        branch, title = f"{ymi_key}-bump-toolchain", f"[{ymi_key}][chore] Bump the toolchain"
    if bootstrap.has_branch(branch):
        die(f"{bootstrap.slug} already has a branch {branch}")

    if ask(tty, f"Push {branch} and open its pull request? (y/n)", "n", YES_NO) != "y":
        print("Nothing pushed.")
        return True
    bootstrap.commit(f"[global] chore: {message}")
    bootstrap.open_pr(branch, title, f"The toolchain bootstrap is built with: {message}.\n\n"
                                     f"The next gyc release is prepared from this, once it is on {bootstrap.default}.")
    print(f"\nMerge it, then run prepare-release again once it is on bootstrap's {bootstrap.default}.")
    return True


# ---------------------------------------------------------------------------------------------
# The release
# ---------------------------------------------------------------------------------------------

def prepare(tty, dry_run: bool, gymir: Repo, bootstrap: Repo, yruntime: Repo, cd_suite: Repo) -> None:
    # The versions
    b_toml = bootstrap.at_default("gyllir.toml")
    b_version = bootstrap.at_default("YMIR_VERSION")

    gyc_default = package_version(b_toml)
    gyc = ask(tty, "gyc to release (GYC_VERSION)", gyc_default)
    if gyc in gymir.releases:
        die(f"gymir already has a release {gyc} - bump bootstrap's gyllir.toml first")
    if gyc != gyc_default:
        warn(f"bootstrap declares {gyc_default}, but a release tags the same version on both repositories")

    major, minor = key(gyc)[:2]
    compiler_default = setting(b_version, "YMIR_BOOTSTRAP_VERSION")
    if minor > 0:
        previous = [t for t in gymir.releases if key(t)[:2] == (major, minor - 1)]
        if previous and previous[-1] != compiler_default:
            warn(f"bootstrap is compiled by gyc {compiler_default}, but {gyc} compiles from {previous[-1]}, "
                 f"the last {major}.{minor - 1} release - bump bootstrap's YMIR_VERSION first")
    compiler = ask(tty, "gyc compiling it (YMIR_BOOTSTRAP_VERSION)", compiler_default)
    if compiler not in gymir.releases:
        die(f"gymir has no release {compiler}")

    compiler_midgard_default = setting(b_version, "MIDGARD_VERSION")
    if (std := std_version(b_toml)) != compiler_midgard_default:
        warn(f"bootstrap's YMIR_VERSION says midgard {compiler_midgard_default}, its gyllir.toml [std] says {std}")
    compiler_midgard = ask(tty, "midgard it is compiled against (YMIR_BOOTSTRAP_MIDGARD_VERSION)",
                           compiler_midgard_default)
    if compiler_midgard not in yruntime.releases:
        die(f"yruntime has no release {compiler_midgard}")

    gcc = ask(tty, "gcc (GCC_VERSION)", setting(b_version, "GCC_VERSION"))
    gyllir = ask(tty, "gyllir (GYLLIR_VERSION)", setting(b_version, "GYLLIR_VERSION"))

    current_midgard = package_version(yruntime.at_default("gyllir.toml"))
    midgard_default = next_minor(current_midgard) if current_midgard in yruntime.releases else current_midgard
    midgard = ask(tty, f"midgard gyc {gyc} bundles", midgard_default)
    if midgard in yruntime.releases:
        die(f"yruntime already has a release {midgard}")

    gyc_key = ask(tty, "gymir work item", "", re.compile(r"^GYC-\d+$"))
    mid_key = ask(tty, "yruntime work item", "", re.compile(r"^MID-\d+$"))
    cd_key = ask(tty, "CD_suite work item (empty for none)", "", re.compile(r"^([A-Z]+-\d+)?$"))

    gymir_branch = f"{gyc_key}-prepare-{gyc}"
    midgard_branch = f"{mid_key}-compile-from-{major}.{minor}"
    for repo, branch in ((gymir, gymir_branch), (yruntime, midgard_branch)):
        if repo.has_branch(branch):
            die(f"{repo.slug} already has a branch {branch}")

    # The branches
    set_setting(yruntime.path / "YMIR_VERSION", "YMIR_BOOTSTRAP_VERSION", gyc)
    if yruntime.dirty():
        yruntime.commit(f"chore: build with gyc {gyc}")
    if current_midgard != midgard:
        toml = yruntime.path / "gyllir.toml"
        toml.write_text(set_package_version(toml.read_text(), midgard))
        yruntime.commit(f"chore: bump version {current_midgard} -> {midgard}")
    if not yruntime.has_commits():
        midgard_branch = yruntime.default
        print(f"yruntime's {midgard_branch} already declares midgard {midgard} built with gyc {gyc}: "
              "gymir bundles it as is.")

    for name, value in (("GYC_VERSION", gyc), ("YMIR_BOOTSTRAP_VERSION", compiler),
                        ("YMIR_BOOTSTRAP_MIDGARD_VERSION", compiler_midgard), ("GCC_VERSION", gcc),
                        ("GYLLIR_VERSION", gyllir), ("MIDGARD_BRANCH", midgard_branch)):
        set_setting(gymir.path / "YMIR_VERSION", name, value)
    if gymir.dirty():
        gymir.commit(f"chore: prepare {gyc}")

    tags = (line.rsplit("refs/tags/", 1)[-1] for line in git(cd_suite.path, "ls-remote", "--tags", "--refs", GYLLIR_REPO).splitlines())
    gyllirs = sorted((t for t in tags if SEMVER.match(t)), key=key)
    deb = cd_suite.path / "amd64" / "deb"
    cd_versions = [s.removeprefix("bootstrap_v") for s in stages.add_stages(deb, gymir.path, yruntime.path, gyllirs, tty)]
    cd_branch = f"{cd_key + '-' if cd_key else ''}add-{'-'.join(cd_versions)}"
    if cd_versions:
        if cd_suite.has_branch(cd_branch):
            die(f"{cd_suite.slug} already has a branch {cd_branch}")
        if shutil.which("uv"):
            for check in ("scripts.check_version_matrix", "scripts.check_remote_tags"):
                if subprocess.run(["uv", "run", "--quiet", "python", "-m", check], cwd=deb).returncode != 0:
                    die("CD_suite's version checks reject the new stages")
        else:
            warn("uv is missing: CD_suite's version checks were not run")
        cd_suite.commit(f"feat: add {human_join(cd_versions)} in the bootstrap chain")

    # The pull requests
    if midgard_branch != yruntime.default:
        yruntime.show(midgard_branch)
    gymir.show(gymir_branch)
    if cd_versions:
        cd_suite.show(cd_branch)
    print()

    if dry_run:
        print("Dry run: nothing pushed.")
        return
    if ask(tty, "Push these branches and open their pull requests? (y/n)", "n", YES_NO) != "y":
        print("Nothing pushed.")
        return

    midgard_link = f"`{midgard_branch}`"
    if midgard_branch != yruntime.default:
        midgard_pr = yruntime.open_pr(
            midgard_branch, f"[{mid_key}][chore] Build with gyc {gyc}",
            f"Midgard {midgard}, built with gyc {gyc}.\n\n"
            f"gymir's {gyc} release bundles this branch (its `MIDGARD_BRANCH`), then dispatches this "
            f"repository's release, which tags {midgard} and merges this pull request. Whatever the {gyc} "
            "compiler requires of the std lands here.")
        midgard_link = f"[`{midgard_branch}`]({midgard_pr})"

    # The check gymir's own release runs on its MIDGARD_BRANCH, now that the branch and its PR exist.
    check = subprocess.run(["bash", str(gymir.path / ".github" / "scripts" / "midgard-branch.sh"),
                            f"--branch={midgard_branch}", f"--expect-gyc={gyc}"], stdout=subprocess.DEVNULL)
    if check.returncode != 0:
        die(f"gymir's release would reject yruntime's {midgard_branch} - gymir's branch was not pushed")

    if gymir.has_commits():
        gymir.open_pr(gymir_branch, f"[{gyc_key}] Prepare {gyc}", f"""Releases gyc {gyc}.

| `YMIR_VERSION` | |
|---|---|
| `GYC_VERSION` | {gyc} |
| `YMIR_BOOTSTRAP_VERSION` | {compiler} |
| `YMIR_BOOTSTRAP_MIDGARD_VERSION` | {compiler_midgard} |
| `GCC_VERSION` | {gcc} |
| `GYLLIR_VERSION` | {gyllir} |
| `MIDGARD_BRANCH` | {midgard_link}, midgard {midgard} |""")

    if cd_versions:
        cd_suite.open_pr(cd_branch, f"{f'[{cd_key}] ' if cd_key else ''}Extend the bootstrap chain to {cd_versions[-1]}",
                         f"Adds {human_join(cd_versions)} to the bootstrap chain.")


def main() -> None:
    parser = argparse.ArgumentParser(prog="prepare-release", description="Opens the pull requests preparing the next gyc release.")
    parser.add_argument("--dry-run", action="store_true", help="print the commits and push nothing")
    args = parser.parse_args()

    # CD_suite's checks run `uv run` there, which must not inherit this project's venv.
    os.environ.pop("VIRTUAL_ENV", None)
    if shutil.which("gh") is None:
        die("gh is required")
    if not args.dry_run and subprocess.run(["gh", "auth", "status"], capture_output=True).returncode != 0:
        die("gh is not authenticated")

    try:
        with tempfile.TemporaryDirectory(prefix="prepare-release.") as work, open("/dev/tty") as tty:
            print(f"Cloning gymir, bootstrap, yruntime and CD_suite in {work}...", flush=True)
            gymir, bootstrap, yruntime, cd_suite = (Repo(Path(work), n) for n in ("gymir", "bootstrap", "yruntime", "CD_suite"))
            if not bump_bootstrap(tty, args.dry_run, bootstrap, gymir, yruntime):
                prepare(tty, args.dry_run, gymir, bootstrap, yruntime, cd_suite)
    except KeyboardInterrupt:
        print(file=sys.stderr)
        sys.exit(130)
