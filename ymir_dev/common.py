"""Layout of the dev directory, its config, and the helpers every command shares."""

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / "ymir-dev.json"
REPOS = ROOT / "repos"
TOOLCHAIN = ROOT / "toolchain"
WORK = ROOT / "work"
BUILD = ROOT / "build"
TARGET = ROOT / "target"
LOGS = ROOT / "logs"

TRIPLE = "x86_64-linux-gnu"


def say(msg: str) -> None:
    print(f"\033[1;34m==>\033[0m {msg}", flush=True)


def die(msg: str) -> "NoReturn":  # noqa: F821
    print(f"\033[1;31merror:\033[0m {msg}", file=sys.stderr)
    sys.exit(1)


def run(cmd: list, cwd: Path | None = None, env: dict | None = None, log: str | None = None) -> None:
    """Runs cmd, to logs/<log>.log when a log name is given, printing its tail on failure."""
    cmd = [str(c) for c in cmd]
    if log is None:
        if subprocess.run(cmd, cwd=cwd, env=env).returncode != 0:
            die(f"`{' '.join(cmd)}` failed")
        return
    LOGS.mkdir(exist_ok=True)
    path = LOGS / f"{log}.log"
    # Writing to a file, stdio buffers by blocks: line-buffer it so the log fills as the step runs.
    if shutil.which("stdbuf"):
        cmd = ["stdbuf", "-oL", "-eL", *cmd]
    with open(path, "wb") as out:
        code = subprocess.run(cmd, cwd=cwd, env=env, stdout=out, stderr=subprocess.STDOUT).returncode
    if code != 0:
        tail = path.read_bytes().replace(b"\0", b"").decode(errors="replace").splitlines()[-40:]
        print("\n".join(tail), file=sys.stderr)
        die(f"{log} failed, full log in {path}")


def env_with_path(*dirs: Path, **extra: str) -> dict:
    env = dict(os.environ)
    env["PATH"] = os.pathsep.join([str(d) for d in dirs] + [env.get("PATH", "")])
    env.update(extra)
    return env


def load_config() -> dict:
    if not CONFIG.exists():
        die(f"no ymir-dev.json, run `uv run start` in {ROOT} first")
    return json.loads(CONFIG.read_text())


def save_config(config: dict) -> None:
    CONFIG.write_text(json.dumps(config, indent=2) + "\n")


def read_shell_vars(path: Path) -> dict:
    """The KEY=VALUE lines of a YMIR_VERSION file."""
    return dict(re.findall(r"^([A-Z_]+)=(\S+)", path.read_text(), re.M))


def toml_version(path: Path, section: str | None = None) -> str:
    """The `version` of a gyllir.toml, top-level or of the given [section]."""
    current = None
    for line in path.read_text().splitlines():
        if m := re.match(r"^\[(.+)\]", line):
            current = m.group(1)
        elif current == section and (m := re.match(r'^version\s*=\s*"([^"]+)"', line)):
            return m.group(1)
    die(f"no version in {path}" + (f" [{section}]" if section else ""))


def short(version: str) -> str:
    m = re.match(r"^(\d+\.\d+)", version)
    if not m:
        die(f"'{version}' is not a <major>.<minor>... version")
    return m.group(1)


def write_if_changed(path: Path, content: str) -> None:
    """Leaves path untouched, mtime included, when it already holds content."""
    if path.exists() and path.read_text() == content:
        return
    path.write_text(content)


def rsync(src: Path, dst: Path, *excludes: str) -> None:
    dst.mkdir(parents=True, exist_ok=True)
    run(["rsync", "-a", "--delete", *[f"--exclude={e}" for e in excludes], f"{src}/", f"{dst}/"])


def require(*tools: str) -> None:
    missing = [t for t in tools if shutil.which(t) is None]
    if missing:
        die(f"missing host tools: {', '.join(missing)}")
