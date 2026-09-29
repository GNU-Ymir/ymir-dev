"""uv run bench: times bench/ with ymirc, an installed gyc, g++ and Python, and writes an HTML report.

Every program in bench/<lang>/ times itself: 2 warmup iterations, then 21 timed ones, printing one
elapsed time in ms per line. Each benchmark runs --rounds times per language, interleaved, with the
ymirc/gyc order flipped on each round so drift in the machine does not favour one compiler.

--gyc takes a gyc binary, or a release version such as 1.3.0, whose .deb is then downloaded and
extracted into build/bench/gyc-<version>/ (no root, the system install is left alone).

Writes build/bench/results.json and build/bench/report.html. Build logs of failures are in
build/bench/logs/.
"""

import argparse
import datetime
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from .common import BUILD, ROOT, TOOLCHAIN, die, load_config, run, say
from .exec_ import gyc_command
from .start import download, relocate_gyc

SUITE = ROOT / "bench"
OUT = BUILD / "bench"
TEMPLATE = Path(__file__).with_name("bench_report.html")
CATEGORY = {
    "loop_sum": "core", "fib_recursive": "core",
    "array_fill_sum": "arrays", "array_sort": "arrays",
    "string_concat": "strings", "string_split": "strings",
    "map_insert": "map", "map_lookup": "map",
    "virtual_dispatch": "oop", "closures": "closures",
    "exceptions": "exceptions", "concurrency": "concurrency",
}
BENCHES = list(CATEGORY)
UNPINNED = {"concurrency"}
WARMUP, REPS = 2, 21
# A benchmark is noisy when, for a compiled language, its slowest round median over its fastest
# exceeds this.
NOISY_RATIO = 1.25


def first_line(cmd: list, pattern: str) -> str:
    out = subprocess.run([str(c) for c in cmd], capture_output=True, text=True).stdout
    m = re.search(pattern, out, re.M)
    return m.group(1) if m else "unknown"


def gyc_versions(cmd: list) -> tuple[str, str]:
    """The Ymir and Midgard versions a gyc reports."""
    out = subprocess.run([str(c) for c in cmd] + ["--version"], capture_output=True, text=True).stdout
    ymir = re.search(r"^Ymir version (\S+)", out, re.M)
    midgard = re.search(r"^Midgard version (\S+)", out, re.M)
    if not ymir:
        die(f"`{' '.join(map(str, cmd))} --version` does not print a Ymir version")
    return ymir.group(1), midgard.group(1) if midgard else "unknown"


def release_gyc(version: str) -> Path:
    """The gyc of a gymir release, extracted into build/bench/gyc-<version>/."""
    major = load_config().get("toolchain", {}).get("gcc_major", "15")
    usr = OUT / f"gyc-{version}" / "usr"
    if not (usr / "bin" / "gyc").exists():
        deb = download(f"https://github.com/GNU-Ymir/gymir/releases/download/{version}/gyc-{major}_{version}_amd64.deb",
                       TOOLCHAIN / "downloads" / f"gyc-{major}_{version}_amd64.deb")
        say(f"extracting gyc {version} into {usr.parent}")
        usr.parent.mkdir(parents=True, exist_ok=True)
        run(["dpkg-deb", "-x", deb, usr.parent])
        relocate_gyc(usr, major)
    return usr / "bin" / "gyc"


def resolve_gyc(arg: str | None) -> Path:
    if arg is None:
        found = shutil.which("gyc")
        if not found:
            die("no gyc on PATH, pass --gyc <path or release version>")
        return Path(found)
    if re.fullmatch(r"\d+\.\d+\.\d+", arg):
        return release_gyc(arg)
    path = Path(arg).expanduser()
    if not path.exists():
        die(f"{path} does not exist")
    return path.resolve()


def fastest_cpu() -> int | None:
    """The CPU with the highest max frequency, cpu0 aside (it takes most interrupts)."""
    freqs = {}
    for d in Path("/sys/devices/system/cpu").glob("cpu[0-9]*"):
        f = d / "cpufreq" / "cpuinfo_max_freq"
        if f.exists():
            freqs[int(d.name[3:])] = int(f.read_text())
    candidates = {c: f for c, f in freqs.items() if c != 0} or freqs
    if not candidates:
        return None
    return max(candidates, key=lambda c: (candidates[c], c))


def cpufreq(cpu: int | None, name: str) -> str | None:
    f = Path(f"/sys/devices/system/cpu/cpu{cpu or 0}/cpufreq/{name}")
    return f.read_text().strip() if f.exists() else None


def power_profile() -> str | None:
    if shutil.which("powerprofilesctl") is None:
        return None
    out = subprocess.run(["powerprofilesctl", "get"], capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else None


def power_warnings(host: dict) -> list:
    """What in the host's power settings makes timings slower or less stable."""
    warns = []
    # intel_pstate reports the powersave governor under every profile, its energy preference is what
    # tells them apart; other drivers have no preference and their governor is the setting.
    if host["epp"] is None and host["governor"] not in (None, "performance", "schedutil"):
        warns.append(f"governor {host['governor']}")
    if host["epp"] not in (None, "performance", "balance_performance"):
        warns.append(f"energy preference {host['epp']}")
    if host["profile"] not in (None, "performance", "balanced"):
        warns.append(f"power profile {host['profile']}")
    return warns


def cpu_model() -> str:
    m = re.search(r"^model name\s*:\s*(.+)$", Path("/proc/cpuinfo").read_text(), re.M)
    return m.group(1).strip() if m else "unknown CPU"


def build(key: str, cmd: list, log: Path) -> bool:
    log.parent.mkdir(parents=True, exist_ok=True)
    with open(log, "w") as out:
        ok = subprocess.run([str(c) for c in cmd], stdout=out, stderr=subprocess.STDOUT).returncode == 0
    if not ok:
        print(f"  {key}: build failed, see {log}", file=sys.stderr)
    return ok


def build_all(benches: list, compilers: dict, opt: str, jobs: int) -> dict:
    """{(lang, bench): command to run it} for every build that succeeded; python needs none."""
    tasks = {}
    for b in benches:
        for key, gyc in compilers.items():
            exe = OUT / "bin" / key / b
            exe.parent.mkdir(parents=True, exist_ok=True)
            tasks[(key, b)] = ([*gyc, opt, SUITE / "ymir" / b / "__lib__.yr", "-o", exe], exe)
        exe = OUT / "bin" / "cpp" / b
        exe.parent.mkdir(parents=True, exist_ok=True)
        extra = ["-pthread"] if b in UNPINNED else []
        tasks[("cpp", b)] = (["g++", opt, "-std=c++20", *extra, "-o", exe, SUITE / "cpp" / f"{b}.cpp"], exe)

    say(f"building {len(tasks)} programs")
    with ThreadPoolExecutor(jobs) as pool:
        done = {k: pool.submit(build, f"{k[0]}/{k[1]}", cmd, OUT / "logs" / k[0] / f"{k[1]}.log")
                for k, (cmd, _) in tasks.items()}
    cmds = {k: [str(tasks[k][1])] for k, f in done.items() if f.result()}
    for b in benches:
        cmds[("python", b)] = [sys.executable, str(SUITE / "python" / f"{b}.py")]
    return cmds


def run_once(cmd: list, cpu: int | None, timeout: float) -> list | str:
    """The samples cmd prints, or why it produced none."""
    pin = ["taskset", "-c", str(cpu)] if cpu is not None else []
    try:
        out = subprocess.run(pin + cmd, cwd=SUITE / "python", capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return f"timed out after {timeout:.0f}s"
    if out.returncode != 0:
        return f"exit {out.returncode}: {out.stderr.strip()[-300:]}"
    samples = []
    for line in out.stdout.splitlines():
        try:
            samples.append(float(line))
        except ValueError:
            pass
    if len(samples) < REPS:
        return f"printed {len(samples)} samples, expected {REPS}"
    return samples


def stats(rounds: list) -> dict:
    s = sorted(x for r in rounds for x in r)
    n = len(s)
    return {"median": statistics.median(s), "p25": s[n // 4], "p75": s[(3 * n) // 4],
            "min": s[0], "max": s[-1], "n": n, "rounds": [statistics.median(r) for r in rounds]}


def is_noisy(results: dict) -> bool:
    for key in ("ymirc", "gyc", "cpp"):
        r = results.get(key)
        if r and len(r["rounds"]) > 1 and max(r["rounds"]) / min(r["rounds"]) > NOISY_RATIO:
            return True
    return False


def main() -> None:
    p = argparse.ArgumentParser(prog="bench", description=__doc__.splitlines()[0])
    p.add_argument("benches", nargs="*", metavar="NAME", help=f"benchmarks to run (default: all of {', '.join(BENCHES)})")
    p.add_argument("--gyc", metavar="PATH|VERSION", help="gyc to compare against: a binary, or a gymir release to fetch (default: gyc on PATH)")
    p.add_argument("--rounds", type=int, default=3, help="runs of each benchmark per language (default: 3)")
    p.add_argument("-O", dest="opt", default="3", help="optimisation level of the Ymir and C++ builds (default: 3)")
    pin = p.add_mutually_exclusive_group()
    pin.add_argument("--cpu", type=int, help="CPU to pin single-threaded benchmarks to (default: the fastest one but cpu0)")
    pin.add_argument("--no-pin", action="store_true", help="do not pin benchmarks to a CPU")
    p.add_argument("-j", type=int, default=os.cpu_count() or 4, help="parallel builds")
    args = p.parse_args()

    unknown = [b for b in args.benches if b not in CATEGORY]
    if unknown:
        die(f"unknown benchmarks: {', '.join(unknown)}")
    benches = args.benches or BENCHES
    if args.rounds < 1:
        die("--rounds must be at least 1")
    if shutil.which("g++") is None:
        die("g++ is missing")
    cpu = None if args.no_pin else args.cpu if args.cpu is not None else fastest_cpu()
    if cpu is not None and shutil.which("taskset") is None:
        die("taskset is missing, install util-linux or pass --no-pin")
    opt = f"-O{args.opt}"

    ymirc = gyc_command([])
    gyc = resolve_gyc(args.gyc)
    ymir, midgard = gyc_versions(ymirc)
    gyc_ymir, gyc_midgard = gyc_versions([gyc])
    series = {
        "ymirc": {"label": "ymirc", "version": f"Ymir {ymir} · Midgard {midgard}"},
        "gyc": {"label": f"gyc {gyc_ymir}", "version": f"Ymir {gyc_ymir} · Midgard {gyc_midgard}", "path": str(gyc)},
        "cpp": {"label": "C++", "version": f"g++ {first_line(['g++', '-dumpfullversion'], r'^(\S+)')} {opt} -std=c++20"},
        "python": {"label": "Python", "version": first_line([sys.executable, "--version"], r"^Python (\S+)")},
    }
    say(f"ymirc: {series['ymirc']['version']}, gyc: {series['gyc']['version']} ({gyc})")
    host = {"model": cpu_model(), "cpu": cpu, "governor": cpufreq(cpu, "scaling_governor"),
            "epp": cpufreq(cpu, "energy_performance_preference"), "profile": power_profile()}
    host["warnings"] = power_warnings(host)
    if host["warnings"]:
        print(f"note: {', '.join(host['warnings'])}: timings are slower and less stable than on a performance setting",
              file=sys.stderr)

    shutil.rmtree(OUT / "bin", ignore_errors=True)
    shutil.rmtree(OUT / "logs", ignore_errors=True)
    cmds = build_all(benches, {"ymirc": ymirc, "gyc": [str(gyc)]}, opt, args.j)
    failures = [f"{series[k]['label']} / {b}: build failed" for k in ("ymirc", "gyc", "cpp")
                for b in benches if (k, b) not in cmds]

    samples = {(k, b): [] for (k, b) in cmds}
    broken = set()
    for r in range(args.rounds):
        compilers = ["ymirc", "gyc"] if r % 2 == 0 else ["gyc", "ymirc"]
        for b in benches:
            for k in [*compilers, "cpp", "python"]:
                if (k, b) not in cmds or (k, b) in broken:
                    continue
                print(f"  round {r + 1}/{args.rounds}  {series[k]['label']:<10} {b}", flush=True)
                got = run_once(cmds[(k, b)], None if b in UNPINNED else cpu, timeout=600)
                if isinstance(got, str):
                    failures.append(f"{series[k]['label']} / {b}: {got}")
                    broken.add((k, b))
                else:
                    samples[(k, b)].append(got)

    rows = []
    for b in benches:
        results = {k: stats(samples[(k, b)]) if samples.get((k, b)) and (k, b) not in broken else None
                   for k in series}
        rows.append({"name": b, "category": CATEGORY[b], "noisy": is_noisy(results), "results": results})

    report = {
        "date": datetime.date.today().isoformat(), "opt": opt, "rounds": args.rounds, "warmup": WARMUP, "reps": REPS,
        "noisy_ratio": NOISY_RATIO, "series": series, "benches": rows, "failures": failures,
        "host": host,
    }
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "results.json").write_text(json.dumps(report, indent=1) + "\n")
    page = TEMPLATE.read_text()
    page = page.replace("__TITLE__", f"ymirc vs {series['gyc']['label']}")
    # </ in a label would close the script element early.
    page = page.replace("/*__REPORT__*/null", json.dumps(report).replace("</", "<\\/"))
    (OUT / "report.html").write_text(page)

    print()
    print(f"{'bench':<18}{'ymirc':>10}{series['gyc']['label']:>12}{'C++':>10}{'Python':>10}{'gyc/ymirc':>11}")
    for row in rows:
        m = {k: (v["median"] if v else None) for k, v in row["results"].items()}
        cell = lambda v, w: f"{v:>{w}.3f}" if v is not None else f"{'-':>{w}}"
        ratio = f"{m['gyc'] / m['ymirc']:>10.2f}x" if m["gyc"] and m["ymirc"] else f"{'-':>11}"
        print(f"{row['name']:<18}{cell(m['ymirc'], 10)}{cell(m['gyc'], 12)}{cell(m['cpp'], 10)}{cell(m['python'], 10)}"
              f"{ratio}{'  noisy' if row['noisy'] else ''}")
    for f in failures:
        print(f"failed: {f}", file=sys.stderr)
    if host["warnings"]:
        print(f"note: measured with {', '.join(host['warnings'])}", file=sys.stderr)
    say(f"report written to {OUT / 'report.html'}")
