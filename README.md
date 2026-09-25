# ymir-dev

Builds a preview gyc from the dev gymir, bootstrap and midgard, and compiles with it.

```sh
uv run start      # clone gymir, bootstrap, midgard (yruntime) and gcc into repos/,
                  # install the gyc + gyllir that bootstrap's YMIR_VERSION pins into toolchain/
uv run preview    # build gyc from them into target/, midgard included
uv run exec main.yr -o main   # target/bin/gyc -iprefix target <args>
ymirc main.yr -o main         # the same, from any directory
```

`start` also installs `~/.local/bin/ymirc`, a symlink to the project venv's `ymirc` entry point. The
project is installed editable, and `ymirc` follows whatever the last `uv run preview` built.

## Releasing

```sh
uv run prepare-release [--dry-run]
```

Opens the pull requests that prepare the next gyc release, one per repository:

- **yruntime**: a branch declaring the midgard that gyc bundles, built with that gyc.
- **gymir**: `YMIR_VERSION` releasing that gyc and bundling the yruntime branch.
- **CD_suite**: the bootstrap chain stages of the gyc releases it does not list yet.

Bootstrap is the source of truth and is bumped by hand beforehand. Every value is asked on the
terminal, with bootstrap's default branch as the default. It works in fresh clones under `/tmp`,
so it does not use `repos/` or any other checkout. It needs `gh` authenticated. `--dry-run`
prints the commits and pushes nothing.

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
- `$(D_TARGET_OBJS)`, which `ymir1` links, is built on its own, so the D frontend is not enabled.

`start` makes the extracted gyc work outside `/usr`. It links in the system `gcc-<major>` pieces
(collect2, crt files, lto plugin). It also adds `lib/gcc/<triple>/<major>/include/ymir`: run from
anywhere but its configured prefix, the driver passes `-iprefix <that dir>` to `ymir1`, and ymirc
silently falls back to `/usr/include/ymir/<v>` when the core is not found there.
