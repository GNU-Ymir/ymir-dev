"""uv run prepare-release [--dry-run]: opens the pull requests preparing the next gyc release."""

import os
import shutil
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "prepare-release.sh"


def main() -> None:
    # The script runs `uv run` in CD_suite, which must not inherit this project's venv.
    env = {k: v for k, v in os.environ.items() if k != "VIRTUAL_ENV"}
    bash = shutil.which("bash") or "/bin/bash"
    os.execve(bash, [bash, str(SCRIPT), *sys.argv[1:]], env)
