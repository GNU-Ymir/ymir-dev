# c-bindgen

Small generators of Ymir bindings out of C headers, written for ysdl3 (BAL-55). They read the headers with regular
expressions, not a C parser: they handle the SDL style (`extern SDL_DECLSPEC ... SDLCALL`, doc comments in `/** */`,
`/**< */` after a field or an enumerator) and need a look over their output on other libraries. Values (enumerators,
`#define`s, sizes) are computed by `gcc`, so `#if` branches and macros resolve as on the machine running them.

- `bindfn.py HEADER [--only REGEX] [--skip REGEX] [--skip-type REGEX]`: the exported functions, as `pub extern (C) fn`
  with their doc (`\param` and `\returns` become `@params:` and `@returns:`). A pointer is `dmut` when it is an output
  (a later argument, a pointer to a scalar or to a pointer) or the object a function named like a mutator (`Set`,
  `Destroy`, `Create`...) changes; `NOT_MUTATING` lists the exceptions. Variadic functions are left out.
- `bindtype.py enum HEADER NAME [TYPE]`: an enum, aliases (`FIRST = X`, same value twice) as `pub def`.
- `bindtype.py defs HEADER REGEX TYPE`: the `#define`s matching REGEX, as `pub def`, in hexadecimal when the header
  writes them so.
- `bindtype.py typedef HEADER NAME`: a scalar typedef, a function pointer (`fn (...)-> T`) or an opaque struct (empty
  record).
- `bindtype.py struct HEADER NAME`: an `@data` record, every field with a default (0, null, the first enumerator, the
  default record), so `Rec()` and `Rec(x-> 12.0f)` both build one.
- `abisizes.py INCLUDE... -- FILE.yr...`: `cte assert (T::size == N);` for every record and enum of the files, N being
  the C `sizeof`, to paste in a `__test` block.

The include paths are those of SDL3 (`/usr/include/SDL3`, `SDL3_image`) in `bindtype.py` (`values`, `first_enumerator`,
`scalar_alias`): change them for another library.

`examples/ysdl3/build_ysdl3.sh SRC_DIR` regenerates every module of ysdl3 (`repos/ysdl3/src/sdl3` in balder-dev), the
`SDL_Event` union (`sdl_event.yr`) and the licence header being the only hand-written parts.
