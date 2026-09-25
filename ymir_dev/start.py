"""uv run start: fetches the dev repos, and installs the gyc and gyllir that build bootstrap.

The toolchain is the one bootstrap's YMIR_VERSION pins (YMIR_BOOTSTRAP_VERSION, GYLLIR_VERSION),
extracted from its release .debs into toolchain/ - no root, the system install is left alone.
"""

import argparse
import os
import shutil
import urllib.request
from pathlib import Path

from .common import (REPOS, ROOT, TOOLCHAIN, TRIPLE, die, load_config, read_shell_vars, require, run,
                     save_config, say, short, toml_version, CONFIG)

REMOTES = {
    "gymir": "https://github.com/GNU-Ymir/gymir.git",
    "bootstrap": "https://github.com/GNU-Ymir/bootstrap.git",
    "midgard": "https://github.com/GNU-Ymir/yruntime.git",
}
GCC_REMOTE = "git://gcc.gnu.org/git/gcc.git"


def download(url: str, dest: Path) -> Path:
    if not dest.exists():
        say(f"downloading {url}")
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp = dest.with_suffix(dest.suffix + ".part")
        try:
            with urllib.request.urlopen(url) as r, open(tmp, "wb") as out:
                shutil.copyfileobj(r, out)
        except OSError as e:
            tmp.unlink(missing_ok=True)
            die(f"could not download {url}: {e}")
        tmp.rename(dest)
    return dest


def fetch_repos(args, config: dict) -> dict:
    repos = config.get("repos", {})
    for name, remote in REMOTES.items():
        given = getattr(args, name)
        if given:
            repos[name] = str(Path(given).expanduser().resolve())
        elif name not in repos:
            dest = REPOS / name
            if not dest.exists():
                say(f"cloning {remote}")
                run(["git", "clone", remote, dest])
            repos[name] = str(dest)
        if not Path(repos[name]).is_dir():
            die(f"{name}: {repos[name]} is not a directory")

    gcc_major = read_shell_vars(Path(repos["bootstrap"]) / "YMIR_VERSION")["GCC_VERSION"].split(".")[0]
    if args.gcc_src:
        repos["gcc"] = str(Path(args.gcc_src).expanduser().resolve())
    elif "gcc" not in repos:
        dest = REPOS / "gcc"
        if not dest.exists():
            say(f"cloning gcc releases/gcc-{gcc_major} (shallow)")
            run(["git", "clone", "--depth=1", f"--branch=releases/gcc-{gcc_major}", GCC_REMOTE, dest])
        repos["gcc"] = str(dest)
    gcc = Path(repos["gcc"])
    if not (gcc / "gcc" / "BASE-VER").exists():
        die(f"{gcc} is not a gcc source tree")
    if not (gcc / "gmp").exists():
        say("fetching gcc prerequisites")
        run(["./contrib/download_prerequisites"], cwd=gcc)
    return repos


def link_missing(system: Path, local: Path) -> None:
    local.mkdir(parents=True, exist_ok=True)
    for entry in system.iterdir():
        if not (local / entry.name).exists() and not (local / entry.name).is_symlink():
            (local / entry.name).symlink_to(entry)


def ensure_host_runtime(bootstrap: Path) -> None:
    """ymir1 is a Ymir program: it links the runtime of the std bootstrap is compiled against."""
    std = toml_version(bootstrap / "gyllir.toml", "std")
    lib = TOOLCHAIN / "usr" / "lib" / f"libgymidgard-debug_{short(std)}.a"
    if not lib.exists():
        download(f"https://github.com/GNU-Ymir/yruntime/releases/download/{std}/libmidgard_debug_{std}.a", lib)


def pinned_toolchain(bootstrap: Path) -> dict:
    """The toolchain the checked-out bootstrap's YMIR_VERSION pins, as ymir-dev.json records it."""
    versions = read_shell_vars(bootstrap / "YMIR_VERSION")
    return {"gyc": versions["YMIR_BOOTSTRAP_VERSION"], "gyllir": versions["GYLLIR_VERSION"],
            "gcc_major": versions["GCC_VERSION"].split(".")[0]}


def install_toolchain(bootstrap: Path, config: dict, force: bool) -> dict:
    wanted = pinned_toolchain(bootstrap)
    gyc, gyllir, major = wanted["gyc"], wanted["gyllir"], wanted["gcc_major"]

    usr = TOOLCHAIN / "usr"
    if force or config.get("toolchain") != wanted:
        shutil.rmtree(usr, ignore_errors=True)
    if not (usr / "bin" / "gyc").exists():
        say(f"installing gyc {gyc} and gyllir {gyllir} into toolchain/")
        downloads = TOOLCHAIN / "downloads"
        for deb in (
            download(f"https://github.com/GNU-Ymir/gymir/releases/download/{gyc}/gyc-{major}_{gyc}_amd64.deb",
                     downloads / f"gyc-{major}_{gyc}_amd64.deb"),
            download(f"https://github.com/GNU-Ymir/Gyllir/releases/download/{gyllir}/gyllir_{gyllir}_amd64.deb",
                     downloads / f"gyllir_{gyllir}_amd64.deb"),
        ):
            run(["dpkg-deb", "-x", deb, TOOLCHAIN])

    # The .deb carries only gyc's own files; collect2, the lto plugin, crtbegin.o... come from
    # the system gcc of the same major, which the relocated driver looks for beside itself.
    for sub in (f"libexec/gcc/{TRIPLE}/{major}", f"lib/gcc/{TRIPLE}/{major}"):
        system, local = Path("/usr") / sub, usr / sub
        if not system.is_dir():
            die(f"{system} is missing: install gcc-{major} and g++-{major}")
        link_missing(system, local)

    # Run from outside /usr, the driver hands ymir1 `-iprefix <lib/gcc/...>/`, where ymirc then
    # looks for include/ymir/<v> - the .deb ships it under libexec only.
    include = usr / f"lib/gcc/{TRIPLE}/{major}/include"
    if include.is_symlink():
        include.unlink()
    include.mkdir(exist_ok=True)
    link_missing(Path("/usr") / f"lib/gcc/{TRIPLE}/{major}/include", include)
    if not (include / "ymir").is_symlink():
        (include / "ymir").symlink_to(usr / f"libexec/gcc/{TRIPLE}/{major}/include/ymir")

    ensure_host_runtime(bootstrap)
    run([usr / "bin" / "gyc", "--version"])
    run([usr / "bin" / "gyllir", "--version"])
    hello = TOOLCHAIN / "hello.yr"
    hello.write_text('use std::io;\n\nfn main () {\n    println ("hello");\n}\n')
    run([usr / "bin" / "gyc", "-fsyntax-only", "-c", hello, "-o", "/dev/null"], log="toolchain-check")
    return wanted


def install_ymirc() -> None:
    """Links ~/.local/bin/ymirc to the venv's `ymirc` entry point: `uv run exec` from anywhere."""
    script = ROOT / ".venv" / "bin" / "ymirc"
    link = Path.home() / ".local" / "bin" / "ymirc"
    if not script.exists():
        die(f"{script} is missing, run `uv sync` in {ROOT}")
    if link.is_symlink() and link.resolve() == script.resolve():
        return
    # A link into another .venv/bin/ymirc is ours, left by a ymir-dev that has since moved.
    if link.is_symlink() and os.readlink(link).endswith("/.venv/bin/ymirc"):
        link.unlink()
    elif link.exists() or link.is_symlink():
        die(f"{link} already exists and is not ours, remove it to install ymirc")
    link.parent.mkdir(parents=True, exist_ok=True)
    link.symlink_to(script)
    say(f"installed {link}")


def main() -> None:
    p = argparse.ArgumentParser(prog="start", description=__doc__.splitlines()[0])
    for name in REMOTES:
        p.add_argument(f"--{name}", metavar="PATH", help=f"use this {name} checkout instead of cloning it")
    p.add_argument("--gcc-src", metavar="PATH", help="use this gcc source tree instead of cloning it")
    p.add_argument("--force-toolchain", action="store_true", help="reinstall gyc and gyllir")
    args = p.parse_args()

    require("git", "rsync", "dpkg-deb", "make", "g++")
    config = load_config() if CONFIG.exists() else {}
    config["repos"] = fetch_repos(args, config)
    config["toolchain"] = install_toolchain(Path(config["repos"]["bootstrap"]), config, args.force_toolchain)
    save_config(config)
    install_ymirc()
    for name, path in config["repos"].items():
        print(f"  {name:<9} {path}")
    say("ready - `uv run preview` builds the dev gyc into target/")
