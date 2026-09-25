"""uv run preview: builds a gyc from the dev gymir, bootstrap and midgard into target/.

As in gymir's docker/Dockerfile.{gyc,midgard}: ymir1 embeds the dev bootstrap, the driver and
ymirc look up the version the dev midgard declares, and that midgard is compiled by the new gyc
and installed beside it (include/ymir/<v>, lib/libgymidgard-*_<v>.a). The repos are never
written to: they are staged into work/ and built there, gcc in build/gcc of its own.
"""

import argparse
import os
import re
import shutil
import subprocess
from pathlib import Path

from . import start
from .common import (BUILD, LOGS, TARGET, TOOLCHAIN, WORK, die, env_with_path, load_config, rsync,
                     run, save_config, say, short, toml_version, write_if_changed)


def farm(src: Path, dst: Path, skip: str) -> None:
    """Mirrors src into dst as symlinks, except the entry named skip."""
    dst.mkdir(parents=True, exist_ok=True)
    for entry in src.iterdir():
        if entry.name == skip:
            continue
        link = dst / entry.name
        if not (link.is_symlink() and os.readlink(link) == str(entry)):
            if link.is_symlink() or link.exists():
                link.unlink()
            link.symlink_to(entry)
    for link in dst.iterdir():
        if link.is_symlink() and not link.exists():
            link.unlink()


def stage(repos: dict, midgard_full: str) -> Path:
    midgard_short = short(midgard_full)
    gcc_src = WORK / "gcc-src"
    farm(Path(repos["gcc"]), gcc_src, "gcc")
    farm(Path(repos["gcc"]) / "gcc", gcc_src / "gcc", "ymir")

    gymir, bootstrap = Path(repos["gymir"]), Path(repos["bootstrap"])
    staged_gymir = gcc_src / "gcc" / "ymir"
    rsync(gymir, staged_gymir, "/.git", "/bootstrap", "/Make-lang.in", "binding/*.o")
    # Make-lang.in names the compiler of ymirc and the binding as /usr/bin/gyc, and compiles the
    # binding against the std gyllir staged in .deps - which it does not do when that std is the
    # one the toolchain gyc bundles, so the binding is then pointed at the bundle.
    usr = TOOLCHAIN / "usr"
    make_lang = (gymir / "Make-lang.in").read_text().replace("/usr/bin/gyc", str(usr / "bin" / "gyc"))
    std = short(toml_version(bootstrap / "gyllir.toml", "std"))
    bundled = next((usr / "lib" / "gcc").glob(f"*/*/include/ymir/{std}"), None)
    if bundled is not None:
        make_lang = re.sub(r"^MIDGARD_IPREFIX = .*$", f"MIDGARD_IPREFIX = {bundled.parents[2]}",
                           make_lang, flags=re.M)
    # The staged bootstrap has no .git: the date `gyc --version` prints is the repo's.
    make_lang = make_lang.replace("git -C $(srcdir)/ymir/bootstrap", f"git -C {bootstrap}")
    write_if_changed(staged_gymir / "Make-lang.in", make_lang)

    staged = staged_gymir / "bootstrap"
    rsync(bootstrap, staged, "/.git", "/.deps", "/.target", "/*.a", "/ymirc.test", "/.ymir_*", "/*.md",
          "/YMIR_VERSION", "/src/ymirc/global/common.yr")
    write_if_changed(staged / "YMIR_VERSION", re.sub(
        r"^MIDGARD_VERSION=.*$", f"MIDGARD_VERSION={midgard_full}",
        (bootstrap / "YMIR_VERSION").read_text(), flags=re.M))
    common = "src/ymirc/global/common.yr"
    write_if_changed(staged / common, re.sub(
        r'^pub lazy MIDGARD_VERSION = "[^"]*";', f'pub lazy MIDGARD_VERSION = "{midgard_short}";',
        (bootstrap / common).read_text(), flags=re.M))
    return gcc_src


def commit_date(repo: Path) -> str:
    out = subprocess.run(["git", "-C", repo, "log", "-1", "--format=%cd", "--date=format:%Y%m%d"],
                         capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else ""


def build_gyc(gcc_src: Path, repos: dict, midgard_full: str, env: dict, jobs: int) -> Path:
    build = BUILD / "gcc"
    build.mkdir(parents=True, exist_ok=True)
    if not (build / "Makefile").exists():
        say("configuring gcc (first run only)")
        # Relative on purpose: Make-lang.in joins $(ROOT_DIR)/$(srcdir).
        configure = os.path.relpath(gcc_src / "configure", build)
        run([configure, f"--prefix={TARGET}", "--enable-languages=c,ymir", "--disable-bootstrap",
             "--disable-multilib", "--enable-checking=release"], cwd=build, env=env, log="configure")

    # gycspec.o sees the midgard version and the dates as flags only, which make does not track.
    ymir_date, midgard_date = commit_date(Path(repos["bootstrap"])), commit_date(Path(repos["midgard"]))
    env = dict(env, MIDGARD_VERSION_DATE=midgard_date)
    stamp = build / ".driver-versions"
    stamp_text = f"{midgard_full} {ymir_date} {midgard_date}"
    if not stamp.exists() or stamp.read_text() != stamp_text:
        (build / "gcc" / "ymir" / "gycspec.o").unlink(missing_ok=True)
        (build / "gcc" / "gyc").unlink(missing_ok=True)
        stamp.write_text(stamp_text)

    say(f"building gcc + ymir1 (-j{jobs}, logs/make.log)")
    # ymir1 links $(D_TARGET_OBJS), which only a build with the D frontend enabled produces.
    run(["make", "configure-gcc"], cwd=build, env=env, log="configure-gcc")
    d_objs = subprocess.run(["make", "-s", "--no-print-directory", "--eval",
                             "print-d-objs: ; @echo $(D_TARGET_OBJS)", "print-d-objs"],
                            cwd=build / "gcc", env=env, capture_output=True, text=True).stdout.split()
    d_objs = [o for o in d_objs if o.endswith(".o")]
    if d_objs:
        run(["make", f"-j{jobs}", *d_objs], cwd=build / "gcc", env=env, log="d-target-objs")
    run(["make", f"-j{jobs}", "all-gcc", "all-target-libgcc"], cwd=build, env=env, log="make")
    say("installing into target/")
    run(["make", "install-gcc", "install-target-libgcc"], cwd=build, env=env, log="install")

    gyc = TARGET / "bin" / "gyc"
    ymir1 = Path(subprocess.run([gyc, "-print-prog-name=ymir1"], capture_output=True, text=True).stdout.strip())
    if not ymir1.is_absolute() or not ymir1.is_relative_to(TARGET) or not ymir1.exists():
        die(f"target gyc resolves ymir1 as '{ymir1}', not the one installed in target/")
    return ymir1.parent


def build_midgard(midgard: Path, libexec: Path, env: dict) -> str:
    version = toml_version(midgard / "gyllir.toml")
    ms = short(version)
    say(f"installing midgard {version} sources")
    for inc in (libexec / "include" / "ymir" / ms, TARGET / "include" / "ymir" / ms):
        inc.mkdir(parents=True, exist_ok=True)
        run(["rsync", "-a", "--delete", "--include=*/", "--include=*.yr", "--exclude=*",
             "--prune-empty-dirs", f"{midgard / 'midgard'}/", f"{inc}/"])

    say("building midgard with the target gyc (logs/midgard.log)")
    staged = WORK / "midgard"
    rsync(midgard, staged, "/.git", "/.target", "/*.a", "/midgard_tests")
    run(["gyllir", "build"], cwd=staged, env=dict(env, PATH=f"{TARGET / 'bin'}{os.pathsep}{env['PATH']}"), log="midgard")
    for name in ("debug", "release", "tests"):
        lib = staged / f"libgymidgard_{name}.a"
        if not lib.exists():
            die(f"gyllir build produced no {lib.name}")
        shutil.copy2(lib, TARGET / "lib" / f"libgymidgard-{name}_{ms}.a")
    return version


def check() -> None:
    from .exec_ import gyc_command

    say("check: hello world through `exec`")
    tmp = WORK / "check"
    tmp.mkdir(parents=True, exist_ok=True)
    (tmp / "main.yr").write_text('use std::io;\n\nfn main () {\n    println ("hello from the dev gyc");\n}\n')
    out = subprocess.run(gyc_command([tmp / "main.yr", "-o", tmp / "main", "-v"]),
                         capture_output=True, text=True)
    if out.returncode != 0:
        print(out.stderr)
        die("hello world did not compile")
    if f"-L{TARGET}" not in out.stderr and str(TARGET / "lib") not in out.stderr:
        die("hello world was not linked against target/lib")
    run([tmp / "main"])

    say("check: midgard test suite")
    run(["./midgard_tests"], cwd=WORK / "midgard", log="midgard-tests")
    tail = (LOGS / "midgard-tests.log").read_bytes().replace(b"\0", b"").decode(errors="replace")
    print("\n".join(tail.splitlines()[-3:]))


def main() -> None:
    p = argparse.ArgumentParser(prog="preview", description=__doc__.splitlines()[0])
    p.add_argument("--clean", action="store_true", help="start work/, build/ and target/ over")
    p.add_argument("--no-midgard", action="store_true", help="rebuild the compiler only")
    p.add_argument("--check", action="store_true", help="then compile and run a hello world and midgard's tests")
    p.add_argument("-j", "--jobs", type=int, default=max(1, (os.cpu_count() or 2) - 1))
    args = p.parse_args()

    config = load_config()
    repos = config["repos"]
    if args.clean:
        say("cleaning work/, build/, target/")
        for d in (WORK, BUILD, TARGET):
            shutil.rmtree(d, ignore_errors=True)

    bootstrap = Path(repos["bootstrap"])
    start.ensure_host_runtime(bootstrap)
    midgard_full = toml_version(Path(repos["midgard"]) / "gyllir.toml")
    std = toml_version(bootstrap / "gyllir.toml", "std")
    say(f"dev midgard {midgard_full}, bootstrap compiled against std {std}")

    # YMIR_BOOTSTRAP_MIDGARD_VERSION names the runtime ymir1 links (Make-lang.in reads it with ?=):
    # the std libymirc.a is compiled against, not the one gymir's YMIR_VERSION last recorded.
    env = env_with_path(TOOLCHAIN / "usr" / "bin", YMIR_BOOTSTRAP_MIDGARD_VERSION=std)
    gcc_src = stage(repos, midgard_full)
    libexec = build_gyc(gcc_src, repos, midgard_full, env, args.jobs)
    if not args.no_midgard:
        config["preview"] = {"midgard": build_midgard(Path(repos["midgard"]), libexec, env)}
        save_config(config)
    run([TARGET / "bin" / "gyc", "--version"])
    if args.check:
        check()
    say("done - `uv run exec <gyc args>` compiles with it")
