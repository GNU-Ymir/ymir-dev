"""Adds to CD_suite's bootstrap chain the gyc releases it does not list yet.

The chain holds one stage per minor, its last patch, since 1.N.* compiles from the last 1.(N-1).*:
a newer patch of the last stage's minor replaces it, and each newer minor is appended. The midgard
each stage bundles, the one its ymir1 links when the previous gyc does not carry it, and the gyllir
it builds are asked on the terminal. Edits utils/versions.py and config.yaml in place, and returns
the name of each stage written.
"""

import re
import subprocess
import sys
import textwrap
from pathlib import Path

SEMVER = re.compile(r"^\d+\.\d+\.\d+$")


def key(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in version.split("."))


def git(repo: str, *args: str) -> str:
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True).stdout


def releases(repo: str) -> list[str]:
    return sorted((t for t in git(repo, "tag", "-l").split() if SEMVER.match(t)), key=key)


def setting(repo: str, ref: str, name: str) -> str | None:
    values = re.findall(rf"^{name}=(.*)$", git(repo, "show", f"{ref}:YMIR_VERSION"), re.M)
    return values[-1].strip() if values else None


def bundled_midgard(gymir: str, yruntime: str, gyc: str) -> str:
    """The midgard a gyc release bundles: named by its YMIR_VERSION until MIDGARD_BRANCH replaced
    it, and since then the yruntime release built with that gyc."""
    named = setting(gymir, gyc, "MIDGARD_VERSION")
    if named:
        return named
    built = [t for t in releases(yruntime) if setting(yruntime, t, "YMIR_BOOTSTRAP_VERSION") == gyc]
    return built[-1] if built else ""


def ask(tty, question: str, default: str) -> str:
    print(f"{question} [{default}]: ", end="", file=sys.stderr, flush=True)
    return tty.readline().strip() or default


def block(text: str, name: str) -> str:
    match = re.search(rf'^    "{re.escape(name)}":.*?^    \),\n', text, re.M | re.S)
    if match is None:
        sys.exit(f"utils/versions.py: no block for the stage {name}")
    return match.group(0)


def ubuntu_name(versions, value: str) -> str:
    names = [n for n in vars(versions) if n.startswith("UBUNTU_FOR_GCC") and getattr(versions, n) == value]
    return names[-1] if names else f'"{value}"'


def minor(version: str) -> str:
    return ".".join(version.split(".")[:2])


def comment(text: str) -> list[str]:
    return textwrap.wrap(text, width=100, initial_indent="        # ", subsequent_indent="        # ")


def describe(v, ubuntu_version: str, pinned: str, prev_gyc: str, carried: str) -> list[str]:
    """The comment heading a stage: its toolchain, and the std its ymir1 links, pinned by the
    bootstrap source, against the midgard carried by the previous gyc's .deb."""
    both = "both " if v.compiler_major == v.target_major else ""
    text = f"target gcc-{v.target_major}, compiled with gcc-{v.compiler_major}, {both}on ubuntu {ubuntu_version}."
    prev = prev_gyc.split("_")[-1]
    if v.bootstrap_midgard:
        text += (f" bootstrap {v.bootstrap} pins std {v.bootstrap_midgard}, which ymir1 links, but gyc {prev}'s"
                 f" .deb only carries midgard {minor(carried)} - so {v.bootstrap_midgard} is built with it first"
                 " (see GycVersions.bootstrap_midgard).")
    elif pinned:
        text += (f" bootstrap {v.bootstrap} pins std {pinned}, which ymir1 links and gyc {prev}'s .deb already"
                 " bundles - nothing to build first.")
    return comment(text)


def render(name: str, comments: list[str], prev_gyc: str, prev_gyllir: str, v, ubuntu: str, gyllir: str,
           trailer: list[str]) -> str:
    linked = f', bootstrap_midgard="{v.bootstrap_midgard}"' if v.bootstrap_midgard else ""
    lines = [
        f'    "{name}": BootstrapStage (',
        *comments,
        f'        prev_gyc="{prev_gyc}",',
        f'        prev_gyllir="{prev_gyllir}",',
        f'        versions=GycVersions (compiler="{v.compiler}", target="{v.target}", ymir="{v.ymir}", '
        f'bootstrap="{v.bootstrap}", midgard="{v.midgard}"{linked}),',
        f"        ubuntu_version={ubuntu},",
    ]
    if gyllir:
        lines.append(
            f'        gyllir=GyllirSpec(gyc="{v.target_major}_{v.bootstrap}", compile_with="{v.target_major}", '
            f'gyllir_version="{gyllir}", ubuntu_version={ubuntu}, prev_gyllir="{prev_gyllir}"),'
        )
    lines += trailer
    lines.append("    ),")
    return "\n".join(lines) + "\n"


def add_stages(deb: Path, gymir: Path, yruntime: Path, gyllirs: list[str], tty) -> list[str]:
    """deb is CD_suite's amd64/deb, gyllirs the gyllir releases, answers are read from tty."""
    gymir, yruntime = str(gymir), str(yruntime)
    gyllirs = [t for t in gyllirs if SEMVER.match(t)]
    sys.path.insert(0, str(deb))
    from utils import versions as V

    last_name = list(V.STAGES)[-1]
    last = V.STAGES[last_name]
    if not isinstance(last, V.BootstrapStage):
        sys.exit(f"utils/versions.py: the last stage {last_name} is not a bootstrap stage")

    newest: dict[tuple[int, ...], str] = {}
    for tag in releases(gymir):
        if key(tag) > key(last.versions.bootstrap):
            newest[key(tag)[:2]] = tag
    if not newest:
        return []

    replaced = newest.pop(key(last.versions.bootstrap)[:2], None)
    chain = ([replaced] if replaced else []) + [newest[minor] for minor in sorted(newest)]
    names = list(V.STAGES)
    producer, produced_gyllir = [
        (n, s.gyllir.gyllir_version)
        for n, s in V.STAGES.items()
        if s.gyllir is not None and not (replaced and n == last_name)
    ][-1]

    versions_py = Path(deb, "utils", "versions.py")
    config = Path(deb, "config.yaml")
    text = versions_py.read_text()
    base_block = block(text, last_name)
    ubuntu = ubuntu_name(V, last.ubuntu_version)
    appended: list[tuple[str, str]] = []
    base = last

    for i, gyc in enumerate(chain):
        if gyc == replaced:
            prev_gyc, prev_gyllir = last.prev_gyc, last.prev_gyllir
            carried = V.STAGES[names[-2]].versions.midgard
        else:
            prev_gyc = f"{base.versions.target_major}_{base.versions.bootstrap}"
            prev_gyllir = produced_gyllir
            carried = base.versions.midgard

        midgard = ask(tty, f"CD_suite: midgard bundled by gyc {gyc}", bundled_midgard(gymir, yruntime, gyc))
        pinned = setting(gymir, gyc, "YMIR_BOOTSTRAP_MIDGARD_VERSION") or ""
        linked = ask(tty, f"CD_suite: midgard ymir1 of gyc {gyc} links, built first (empty for none)",
                     pinned if pinned and minor(pinned) != minor(carried) else "")
        newer = [g for g in gyllirs if not SEMVER.match(produced_gyllir) or key(g) > key(produced_gyllir)]
        default = newer[-1] if newer and i == len(chain) - 1 else ""
        gyllir = ask(tty, f"CD_suite: gyllir built with gyc {gyc} (empty for none)", default)

        v = V.GycVersions(compiler=base.versions.compiler, target=base.versions.target,
                          ymir=gyc, bootstrap=gyc, midgard=midgard, bootstrap_midgard=linked or None)
        name = f"bootstrap_v{gyc}"
        trailer = [] if gyllir or newer else comment(f"No gyllir release after {produced_gyllir} (already built by {producer}).")
        rendered = render(name, describe(v, last.ubuntu_version, pinned, prev_gyc, carried),
                          prev_gyc, prev_gyllir, v, ubuntu, gyllir, trailer)
        if gyc == replaced:
            text = text.replace(base_block, rendered)
        else:
            appended.append((name, rendered))

        if gyllir:
            producer, produced_gyllir = name, gyllir
        base = V.BootstrapStage(prev_gyc=prev_gyc, prev_gyllir=prev_gyllir, versions=v,
                                ubuntu_version=last.ubuntu_version)

    end = text.rstrip().rindex("}")
    text = text[:end] + "".join(r for _, r in appended) + text[end:]
    versions_py.write_text(text)

    lines = config.read_text().splitlines(keepends=True)
    if replaced:
        lines = [f"- bootstrap_v{replaced}\n" if l.strip() == f"- {last_name}" else l for l in lines]
    listed = max(i for i, l in enumerate(lines) if l.startswith("- "))
    lines[listed + 1:listed + 1] = [f"- {n}\n" for n, _ in appended]
    config.write_text("".join(lines))

    return [f"bootstrap_v{gyc}" for gyc in chain]
