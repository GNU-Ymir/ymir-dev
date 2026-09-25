# ymir-dev

Builds a preview gyc from the dev gymir, bootstrap and midgard, and compiles with it.

```sh
uv run start      # clone gymir, bootstrap, midgard (yruntime) and gcc into repos/,
                  # install the gyc + gyllir that bootstrap's YMIR_VERSION pins into toolchain/
uv run preview    # build gyc from them into target/, midgard included
uv run exec main.yr -o main   # target/bin/gyc -iprefix target <args>
ymirc main.yr -o main         # the same, from any directory
uv run tests                  # compile and run tests/, checking their expected outputs
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
