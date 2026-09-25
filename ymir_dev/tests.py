"""uv run tests: compiles and runs tests/**/*.yr with the target/ gyc, against their expected outputs.

A case is tests/<suite>/<name>.yr, next to files of the same basename:

    <name>.out     the exact stdout of the program (required)
    <name>.status  its exit status, a number or a signal name as SIGABRT (default 0)
    <name>.stderr  lines its stderr must contain, in that order (the text differs with -g)
    <name>.in      its stdin (default empty)
    <name>.flags   extra gyc flags, on one line

Each case is compiled and run once per mode, `debug` (-g) and `release` (-O2) by default. The
output of a failing run is left in build/tests/<suite>/<name>.<mode>.{out,err,status}; --update
writes it as the expected files instead.
"""

import argparse
import difflib
import os
import re
import shlex
import signal
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path

from .common import BUILD, ROOT, die, say
from .exec_ import gyc_command

TESTS = ROOT / "tests"
OUT = BUILD / "tests"
MODES = {"debug": ["-g"], "release": ["-O2"]}
ANSI = re.compile(r"\x1b\[[0-9;]*m")


@dataclass
class Result:
    case: Path
    mode: str
    ok: bool
    report: str = ""
    produced: dict | None = None
    stderr_ok: bool = True


def status_name(code: int) -> str:
    if code < 0:
        try:
            return signal.Signals(-code).name
        except ValueError:
            return f"signal {-code}"
    return str(code)


def expected(case: Path, ext: str, default: str | None = None) -> str | None:
    path = case.with_suffix(ext)
    return path.read_text() if path.exists() else default


def stderr_missing(want: str, got: str) -> list:
    """The lines of want that got does not contain, in order."""
    lines, missing, at = got.splitlines(), [], 0
    for line in want.splitlines():
        found = next((i for i in range(at, len(lines)) if line in lines[i]), None)
        if found is None:
            missing.append(line)
        else:
            at = found + 1
    return missing


def diff(want: str, got: str, what: str) -> str:
    return "".join(difflib.unified_diff(want.splitlines(True), got.splitlines(True),
                                        f"expected {what}", f"actual {what}"))


def run_case(case: Path, mode: str, timeout: float) -> Result:
    rel = case.relative_to(TESTS)
    work = OUT / rel.parent
    work.mkdir(parents=True, exist_ok=True)
    binary = work / f"{case.stem}.{mode}"
    flags = shlex.split(expected(case, ".flags", ""))
    # Compiled from tests/, so that the paths in the diagnostics and panics are rel. gyc writes
    # its diagnostics on stdout.
    compiled = subprocess.run(gyc_command([*MODES[mode], *flags, rel, "-o", binary]), cwd=TESTS,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if compiled.returncode != 0:
        return Result(case, mode, False, "compilation failed:\n" + ANSI.sub("", compiled.stdout))

    try:
        ran = subprocess.run([binary], cwd=work, input=expected(case, ".in", ""),
                             capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return Result(case, mode, False, f"timed out after {timeout}s")
    got_status, got_err = status_name(ran.returncode), ANSI.sub("", ran.stderr)
    want_out = expected(case, ".out")
    want_status = expected(case, ".status", "0").strip()
    want_err = expected(case, ".stderr", "")

    report = []
    if want_out is None:
        report.append(f"no {rel.with_suffix('.out')}")
    elif ran.stdout != want_out:
        report.append(diff(want_out, ran.stdout, "stdout"))
    if got_status != want_status:
        report.append(f"exit status {got_status}, expected {want_status}")
    if missing := stderr_missing(want_err, got_err):
        report.append("stderr lacks:\n" + "".join(f"  {m}\n" for m in missing))
    if report and got_err:
        report.append("stderr:\n" + got_err)
    produced = {".out": ran.stdout, ".err": got_err, ".status": got_status + "\n"}
    if not report:
        for path in (binary, *(work / f"{case.stem}.{mode}{ext}" for ext in produced)):
            path.unlink(missing_ok=True)
        return Result(case, mode, True)
    for ext, text in produced.items():
        (work / f"{case.stem}.{mode}{ext}").write_text(text)
    return Result(case, mode, False, "\n".join(report), produced, not missing)


def update(result: Result) -> None:
    """Writes what the run produced as the expected files of its case."""
    case, produced = result.case, result.produced
    case.with_suffix(".out").write_text(produced[".out"])
    status = case.with_suffix(".status")
    if produced[".status"].strip() == "0":
        status.unlink(missing_ok=True)
    else:
        status.write_text(produced[".status"])


def collect(filters: list) -> list:
    cases = sorted(TESTS.rglob("*.yr"))
    if filters:
        cases = [c for c in cases if any(f in str(c.relative_to(TESTS)) for f in filters)]
    return cases


def main() -> None:
    p = argparse.ArgumentParser(prog="tests", description=__doc__.splitlines()[0])
    p.add_argument("filters", nargs="*", help="run the cases whose path under tests/ contains one of them")
    p.add_argument("-m", "--mode", action="append", choices=MODES,
                   help="a mode to run the cases in (repeatable, default: all)")
    p.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 1)
    p.add_argument("-t", "--timeout", type=float, default=10.0, help="seconds a program may run")
    p.add_argument("-l", "--list", action="store_true", help="list the cases and exit")
    p.add_argument("--update", action="store_true",
                   help="write the output of the failing runs as their expected .out/.status")
    args = p.parse_args()

    cases = collect(args.filters)
    if not cases:
        die(f"no case under {TESTS} matches {' '.join(args.filters)}")
    if args.list:
        print("\n".join(str(c.relative_to(TESTS)) for c in cases))
        return
    modes = args.mode or list(MODES)
    say(f"{len(cases)} cases x {', '.join(modes)}")

    with ThreadPoolExecutor(args.jobs) as pool:
        futures = [pool.submit(run_case, c, m, args.timeout) for c in cases for m in modes]
        results = []
        for future in futures:
            r = future.result()
            results.append(r)
            name = f"{r.case.relative_to(TESTS).with_suffix('')} [{r.mode}]"
            print(f"\033[1;32mok\033[0m   {name}" if r.ok else f"\033[1;31mFAIL\033[0m {name}", flush=True)

    failed = [r for r in results if not r.ok]
    for r in failed:
        print(f"\n\033[1;31m--- {r.case.relative_to(TESTS)} [{r.mode}]\033[0m\n{r.report.rstrip()}", flush=True)
    if args.update:
        # One mode's output per case: the expected files are the same for every mode.
        done = set()
        for r in failed:
            if r.produced is not None and r.case not in done:
                update(r)
                done.add(r.case)
                say(f"updated {r.case.relative_to(TESTS).with_suffix('')} from its {r.mode} run")
        # --update never writes a .stderr: a run lacking one of its lines still fails.
        failed = [r for r in failed if r.produced is None or not r.stderr_ok]
    print()
    if failed:
        die(f"{len(failed)} of {len(results)} runs failed")
    say(f"all {len(results)} runs passed")
