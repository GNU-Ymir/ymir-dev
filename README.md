# ymir-dev

Builds a preview gyc from the dev gymir, bootstrap and midgard, and compiles with it.

```sh
uv run start      # clone gymir, bootstrap, midgard (yruntime) and gcc into repos/,
                  # install the gyc + gyllir that bootstrap's YMIR_VERSION pins into toolchain/
uv run preview    # build gyc from them into target/, midgard included
uv run exec main.yr -o main   # target/bin/gyc -iprefix target <args>
ymirc main.yr -o main         # the same, from any directory
uv run tests                  # compile and run tests/, checking their expected outputs
uv run bench                  # time bench/ with ymirc, gyc, C++ and Python, into an HTML report
```

`preview` builds whatever each repo has checked out, branch and uncommitted changes included. When
the checked-out bootstrap pins another gyc or gyllir than `toolchain/` holds, `preview` reinstalls
it first, so switching bootstrap branches needs no new `start`.

`start` also installs `~/.local/bin/ymirc`, a symlink to the project venv's `ymirc` entry point. The
project is installed editable, and `ymirc` follows whatever the last `uv run preview` built.

## Tests

```sh
uv run tests                      # every case, in debug (-g) and release (-O2)
uv run tests generators -m debug  # the cases whose path contains `generators`, in debug only
uv run tests --update             # write what the failing runs produced as their expected files
```

Compiles each `tests/<suite>/<name>.yr` with the preview gyc, runs it, and checks what it did
against the files of the same basename:

| file | checks |
|---|---|
| `<name>.out` | the exact stdout (required) |
| `<name>.status` | the exit status, a number or a signal name like `SIGABRT` (default `0`) |
| `<name>.stderr` | lines the stderr must contain, in that order (the panic trace differs with `-g`) |
| `<name>.in` | fed to stdin |
| `<name>.flags` | extra gyc flags |

A failing run leaves its binary, stdout, stderr and status in `build/tests/<suite>/<name>.<mode>.*`.
To add a case, write the `.yr`, run `uv run tests <name> --update`, and **read the `.out` it wrote**
before committing it. `--update` writes `.out` and `.status` only. A `.stderr` is written by hand.

## Benchmarks

```sh
uv run bench                          # every benchmark, the preview against the gyc on PATH
uv run bench --gyc 1.3.0              # against a gymir release, fetched into build/bench/gyc-1.3.0
uv run bench --gyc /path/to/gyc       # against any gyc binary
uv run bench map_insert map_lookup    # only these benchmarks
```

`bench/` holds each benchmark once per language: `ymir/<name>/__lib__.yr`, `cpp/<name>.cpp` and
`python/<name>.py`. Every program times itself (2 warmup iterations, then 21 timed ones, one ms
value per line). The preview gyc (`ymirc`), the other gyc and `g++` build them at `-O3` (`-O` to
change it). Each benchmark then runs `--rounds` times per language (3 by default). The rounds are
interleaved and flip the ymirc/gyc order each time, so a drift in the machine hits both compilers
alike.

Single-threaded benchmarks are pinned to the fastest CPU but cpu0 (`--cpu N` picks one, `--no-pin`
turns it off). A benchmark whose round medians differ by more than 25% for a compiled language is
marked noisy and left out of the summary. On a power-saving profile, tight loops can run 3× slower
from one run to the next. The report flags that setting, and `powerprofilesctl set performance`
before a run gives numbers worth comparing.

The results land in `build/bench/results.json` and `build/bench/report.html`. The report has
the speedup of ymirc over the other gyc, each language against C++, and every median with its
p25–p75 range. The logs of failed builds are in `build/bench/logs/`.

## Releasing

```sh
uv run prepare-release [--dry-run]
```

Opens the pull requests that prepare the next gyc release, one per repository:

- **yruntime**: a branch declaring the midgard that gyc bundles, built with that gyc.
- **gymir**: `YMIR_VERSION` releasing that gyc and bundling the yruntime branch.
- **CD_suite**: the bootstrap chain stages of the gyc releases it does not list yet.

Bootstrap is the source of truth. Every value is asked on the terminal, with bootstrap's default
branch as the default. First, it offers to edit bootstrap's `YMIR_VERSION` in `$VISUAL`/`$EDITOR`
(vim by default). If you change it, it asks for the bootstrap work item (`YMI-*`), opens that
bootstrap pull request, and stops there: merge it, then run `prepare-release` again once the
change is on bootstrap's default branch. It works in fresh clones under `/tmp`, so it does not use
`repos/` or any other checkout. It needs `gh` authenticated. `--dry-run` prints the commits and
pushes nothing.

### Release workflow

gyc `<v>` is released from the heads of bootstrap's and gymir's default branches, and bundles a
new midgard, the next minor of yruntime's last tag:

1. **Tickets.** In Plane, one `Prepare <v>` work item per repository that gets a branch: `GYC-*`
   (gymir) and `MID-*` (yruntime). Add a `YMI-*` (bootstrap) when bootstrap's `YMIR_VERSION`
   changes, and a `BUILD-*` (CD_suite) when prepare-release has chain stages to add. The branches
   and pull request titles are named after these keys.
2. **Bootstrap.** Its default branch declares `<v>` (`gyllir.toml`'s `version`) and the toolchain
   that compiles it (`YMIR_VERSION`: the last gyc of the previous minor, and the midgard it
   compiles against). To change the toolchain, run `prepare-release`, edit `YMIR_VERSION` when
   asked, and merge the `YMI-*` pull request it opens.
3. **Tag bootstrap.** Dispatch bootstrap's *Release* workflow on its default branch. It tags `<v>`
   and publishes `libymirc`. gymir's release checks this tag out and fails without it.
4. **`uv run prepare-release`.** It opens:
   - yruntime `MID-*-compile-from-<major.minor>`: `YMIR_BOOTSTRAP_VERSION=<v>`, and the midgard
     version bumped to the next minor;
   - gymir `GYC-*-prepare-<v>`: `YMIR_VERSION` restating bootstrap's, with `MIDGARD_BRANCH` on the
     yruntime branch;
   - CD_suite: the stages of the released gyc it does not list yet. The gyc being prepared is not
     released yet, so its stage comes with the next release.
5. **Midgard.** Whatever the new gyc requires of the std goes on the yruntime branch. Leave its
   pull request open: the release merges it.
6. **Merge gymir's pull request**, then dispatch gymir's *Release* workflow. It builds gyc from the
   bootstrap tag, bundles the head of `MIDGARD_BRANCH`, and publishes the `.deb`. Then it
   dispatches yruntime's release, which builds midgard with that gyc, tags its version, and merges
   the yruntime pull request.

## Existing checkouts

To reuse existing checkouts instead of cloning, pass them to `start` once (they are remembered in
`ymir-dev.json`):

```sh
uv run start --gymir ~/ymir/gcc/gcc-src/gcc/ymir \
             --bootstrap ~/ymir/gcc/gcc-src/gcc/ymir/bootstrap \
             --midgard ~/ymir/midgard --gcc-src ~/ymir/gcc/gcc-src
```

`preview` options: `--check` (then compile and run a hello world and midgard's test suite),
`--no-midgard` (compiler only), `--clean`, `-j N`. The first run is a full GCC build. Later runs
are incremental.

## What goes where

| dir | contents |
|---|---|
| `repos/` | the clones made by `start` |
| `toolchain/` | the pinned gyc and gyllir, extracted from their release .debs (no root needed) |
| `work/` | the staged sources: a symlink farm of gcc, with copies of gymir and bootstrap in it, plus midgard |
| `build/gcc` | the GCC build dir |
| `tests/` | the execution tests of `uv run tests` |
| `build/tests` | the runs of the failing tests |
| `bench/` | the benchmarks of `uv run bench`, in Ymir, C++ and Python |
| `build/bench` | their binaries, `results.json`, `report.html`, and any release gyc `--gyc` fetched |
| `target/` | the preview install: `bin/gyc`, `libexec/.../ymir1`, `include/ymir/<v>`, `lib/libgymidgard-*_<v>.a` |
| `logs/` | configure, make, install, midgard build logs |

`preview` never writes into the repos. It stages them into `work/` and makes these changes to
the staged copies only:

- The midgard version declared by the dev midgard's `gyllir.toml` is baked into bootstrap
  (`YMIR_VERSION`, `common.yr`) and the driver, as the release Dockerfiles do. The preview gyc
  looks up that version.
- `Make-lang.in`'s `/usr/bin/gyc` becomes `toolchain/usr/bin/gyc`. When the std that bootstrap
  pins is the one that gyc bundles, gyllir stages no `.deps`, so the binding's `MIDGARD_IPREFIX`
  is pointed at that bundle.
- `ymir1` links the midgard runtime of the std pinned by bootstrap's `gyllir.toml`
  (`YMIR_BOOTSTRAP_MIDGARD_VERSION`). If `toolchain/` doesn't have it yet, it is downloaded from
  the yruntime release.

`start` makes the extracted gyc work outside `/usr`. It links in the system `gcc-<major>` pieces
(collect2, crt files, lto plugin). It also adds `lib/gcc/<triple>/<major>/include/ymir`: run from
anywhere but its configured prefix, the driver passes `-iprefix <that dir>` to `ymir1`, and ymirc
silently falls back to `/usr/include/ymir/<v>` when the core is not found there.
