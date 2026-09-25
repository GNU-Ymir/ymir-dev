"""uv run exec <args>: runs the target/ gyc with -iprefix on the dev midgard it was built with."""

import os
import sys

from .common import ROOT, TARGET, die, load_config, short


def gyc_command(args: list) -> list:
    config = load_config()
    if "preview" not in config:
        die(f"no preview built yet, run `uv run preview` in {ROOT} first")
    gyc = TARGET / "bin" / "gyc"
    # ymirc falls back to /usr/include/ymir/<v> in silence when the -iprefix one is missing.
    core = TARGET / "include" / "ymir" / short(config["preview"]["midgard"])
    if not gyc.exists() or not core.is_dir():
        die(f"{gyc} or {core} is missing, rerun `uv run preview` in {ROOT}")
    return [str(gyc), "-iprefix", str(TARGET), *[str(a) for a in args]]


def main() -> None:
    cmd = gyc_command(sys.argv[1:])
    os.execv(cmd[0], cmd)
