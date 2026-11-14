"""uv run install-emacs [--dir DIR]: links editors/emacs/yr-mode.el into DIR (~/.elisp by default)."""

import argparse
import filecmp
import shutil
from pathlib import Path

from .common import ROOT, die, say

MODE = ROOT / "editors" / "emacs" / "yr-mode.el"


def install(directory: Path) -> None:
    """Links directory/yr-mode.el to the mode of the repo, so a `git pull` updates it in place."""
    if not MODE.exists():
        die(f"{MODE} is missing")
    link = directory / MODE.name
    if link.is_symlink() and link.resolve() == MODE.resolve():
        say(f"{link} already links to {MODE}")
        return
    directory.mkdir(parents=True, exist_ok=True)
    if link.is_symlink():
        link.unlink()
    elif link.exists():
        # A copy installed by hand: kept aside when it differs, it may hold local changes.
        if not filecmp.cmp(link, MODE, shallow=False):
            backup = link.with_name(link.name + ".bak")
            shutil.move(link, backup)
            say(f"moved the previous {link} to {backup}")
        else:
            link.unlink()
    link.symlink_to(MODE)
    say(f"installed {link} -> {MODE}")

    # A compiled copy beside it would be loaded instead of the linked source.
    stale = link.with_suffix(".elc")
    if stale.exists():
        stale.unlink()
        say(f"removed the stale {stale}")


def main() -> None:
    p = argparse.ArgumentParser(prog="install-emacs", description=__doc__.splitlines()[0])
    p.add_argument("--dir", type=Path, default=Path.home() / ".elisp",
                   help="the directory to link the mode into (default: ~/.elisp)")
    args = p.parse_args()

    directory = args.dir.expanduser()
    install(directory)
    print(f"Load it from your init file, if it is not yet:\n"
          f"  (add-to-list 'load-path \"{directory}\")\n"
          f"  (require 'yr-mode)\n"
          f"then M-x load-file RET {directory / MODE.name} RET to reload it in a running Emacs.")
