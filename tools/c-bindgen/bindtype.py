"""Ymir enums and constants out of an SDL3 header, their values computed by the C compiler.

usage:
  bindtype.py enum HEADER ENUMNAME [TYPE]          -> pub enum ENUMNAME | ... ;
  bindtype.py defs HEADER REGEX TYPE                -> pub def NAME = value; for each #define matching REGEX
  bindtype.py typedef HEADER NAME                   -> pub def NAME: type; of a scalar or function pointer typedef
  bindtype.py struct HEADER STRUCTNAME              -> @data pub record STRUCTNAME { ... }, every field with a default
"""
import os
import re
import subprocess
import sys
import tempfile
import glob

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bindfn as gen  # noqa: E402

SUFFIX = {"u8": "u8", "u16": "u16", "u32": "u32", "u64": "u64", "i32": "", "i64": "i64", "f32": "f"}


def values(header: str, names: list[str], signed: bool) -> dict[str, int]:
    fmt = "%lld" if signed else "%llu"
    cast = "long long" if signed else "unsigned long long"
    src = "#include <SDL3/SDL.h>\n#include <SDL3_image/SDL_image.h>\n#include <stdio.h>\nint main(void){\n"
    for n in names:
        src += f'printf("{n} {fmt}\\n", ({cast})({n}));\n'
    src += "return 0;}\n"
    with tempfile.TemporaryDirectory() as d:
        c = os.path.join(d, "v.c")
        open(c, "w").write(src)
        exe = os.path.join(d, "v")
        subprocess.run(["gcc", c, "-o", exe, "-w"], check=True)
        out = subprocess.run([exe], check=True, capture_output=True, text=True).stdout
    return {l.split()[0]: int(l.split()[1]) for l in out.splitlines()}


def comment_of(text: str) -> str:
    m = re.search(r"/\*\*<\s*(.*?)\s*\*/", text, re.S)
    if not m:
        return ""
    return " ".join(m.group(1).split())


def literal(v: int, ty: str, hexa: bool) -> str:
    if hexa and v >= 0:
        return f"0x{v:X}{SUFFIX[ty]}"
    return f"{v}{SUFFIX[ty]}"


def type_doc(src: str, pattern: str):
    """Print the doc comment right before the declaration matching pattern."""
    m = re.search(r"/\*\*((?:(?!\*/).)*?)\*/\s*" + pattern, src, re.S)
    if not m:
        return False
    print("/**")
    for l in gen.clean_doc(m.group(1)):
        for w in gen.wrap(l):
            print(w)
    print(" */")
    return True


def typedef(header: str, name: str):
    """pub def NAME: type; of a typedef of a scalar, a pointer or a function pointer, an empty record of an opaque
    struct"""
    src = open(header).read()
    if re.search(r"typedef struct " + name + r"\s+" + name + r"\s*;", src) and not re.search(r"^struct " + name + r"\s*\{", src, re.M):
        type_doc(src, r"typedef struct " + name + r"\s+" + name + r"\s*;")
        print(f"pub record {name} {{}}")
        print()
        return
    m = re.search(r"typedef\s+([^;{}]*?)\(\s*(?:SDLCALL\s*)?\*\s*" + name + r"\s*\)\s*\(([^;]*?)\)\s*;", src, re.S)
    if m:
        ret, _ = gen.ymir_type(m.group(1).strip())
        params = []
        for ctype, _ in gen.split_params(" ".join(m.group(2).split())):
            ty, mut = gen.ymir_type(ctype)
            params.append(("dmut " if mut and ty.startswith("*") else "") + ty)
        type_doc(src, r"typedef\s+[^;{}]*?\(\s*(?:SDLCALL\s*)?\*\s*" + name + r"\b")
        print(f"pub def {name}: fn ({', '.join(params)})-> {ret};")
        print()
        return
    m = re.search(r"typedef\s+([\w\s\*]+?)\s*\b" + name + r"\s*;", src)
    ty, _ = gen.ymir_type(m.group(1))
    type_doc(src, r"typedef\s+[\w\s\*]+?\b" + name + r"\s*;")
    print(f"pub def {name}: {ty};")
    print()


def enum(header: str, name: str, ty: str | None):
    src = open(header).read()
    type_doc(src, r"typedef enum " + name + r"\b")
    m = re.search(r"typedef enum " + name + r"\s*\{(.*?)\}\s*" + name + ";", src, re.S)
    body = m.group(1)
    # plain comments go, the doc comment of an enumerator is put aside (it may hold commas) and moved before its
    # comma, then one entry per comma
    body = re.sub(r"/\*(?!\*<).*?\*/", "", body, flags=re.S)
    body = re.sub(r"^\s*#.*$", "", body, flags=re.M)
    docs = []
    body = re.sub(r"/\*\*<.*?\*/", lambda d: docs.append(comment_of(d.group(0))) or f"@{len(docs) - 1}@", body, flags=re.S)
    body = re.sub(r",\s*(@\d+@)", r" \1,", body)
    entries = []
    for part in body.split(","):
        m = re.match(r"\s*(\w+)\s*(?:=\s*(.*?))?\s*(?:@(\d+)@)?\s*$", part, re.S)
        if not m or not m.group(1).startswith(("SDL_", "IMG_")):
            continue
        entries.append((m.group(1), (m.group(2) or "").strip(), docs[int(m.group(3))] if m.group(3) else ""))
    names = [n for n, _, _ in entries]
    vals = values(header, names, signed=True)
    if ty is None:
        ty = "i32" if any(v < 0 for v in vals.values()) else "u32"
    hexa = any(init.startswith("0x") for _, init, _ in entries)
    # an enumerator naming another, or repeating its value, is an alias: a def of the member holding its value (the
    # value the compiler gives it, so the branch of an #if that applies is the one kept)
    seen, members, alias_names = {}, [], []
    for n, init, com in entries:
        if "PADDING" in n or n in seen.values() or n in [a for a, _ in alias_names]:
            continue
        if (init and re.fullmatch(r"(SDL|IMG)_\w+", init) and init in names) or vals[n] in seen:
            alias_names.append((n, com))
            continue
        seen[vals[n]] = n
        members.append((n, vals[n], com))
    aliases = [(n, seen[vals[n]], com) for n, com in alias_names]
    width = max(len(n) for n, _, _ in members)
    print(f"pub enum {name}")
    for i, (n, v, com) in enumerate(members):
        end = ";" if i == len(members) - 1 else ""
        c = f" /**< {com} */" if com else ""
        print(f"| {n.ljust(width)} = {literal(v, ty, hexa)}{end}{c}")
    if aliases:
        print()
    for n, target, com in aliases:
        if com:
            print(f"/** {com} */")
        print(f"pub def {n} = {name}::{target};")


def defs(header: str, regex: str, ty: str):
    src = open(header).read()
    found = []
    for m in re.finditer(r"#define\s+(?P<name>" + regex + r")\s+(?P<rest>.*)", src):
        n, rest = m.group("name"), m.group("rest")
        if "(" in n:
            continue
        found.append((n, rest.strip().startswith(("0x", "SDL_UINT64_C(0x")) or "0x" in rest, comment_of(rest)))
    vals = values(header, [n for n, _, _ in found], signed=ty.startswith("i"))
    width = max(len(n) for n, _, _ in found)
    # a group written in hexadecimal stays so, the members combining others included
    group_hexa = not ty.startswith("i") and any(h for _, h, _ in found)
    for n, hexa, com in found:
        hexa = hexa or group_hexa
        c = f" /**< {com} */" if com else ""
        print(f"pub def {n.ljust(width)} = {literal(vals[n], ty, hexa)};{c}")


def first_enumerator(ty: str) -> str | None:
    """The first enumerator of the enum ty of any SDL header, None if ty is no enum."""
    for h in sorted(glob.glob("/usr/include/SDL3/*.h")) + glob.glob("/usr/include/SDL3_image/*.h"):
        m = re.search(r"typedef enum " + ty + r"\s*\{(.*?)\}", open(h).read(), re.S)
        if m:
            body = re.sub(r"/\*.*?\*/", "", m.group(1), flags=re.S)
            return re.search(r"\b(SDL_\w+|IMG_\w+)", body).group(1)
    return None


def scalar_alias(ty: str) -> str | None:
    """The Ymir scalar type ty is a typedef of, None if it is none."""
    for h in sorted(glob.glob("/usr/include/SDL3/*.h")):
        m = re.search(r"typedef\s+(\w+)\s+" + ty + r"\s*;", open(h).read())
        if m and m.group(1) in gen.SCALARS:
            return gen.SCALARS[m.group(1)]
    return None


def default(ty: str) -> str:
    if ty.startswith("*") or ty.startswith("fn"):
        return "null"
    if ty == "bool":
        return "false"
    if ty in ("f32", "f64"):
        return "0.0f" if ty == "f32" else "0.0"
    if ty in gen.SCALARS.values():
        return "0"
    alias = scalar_alias(ty)
    if alias:
        return default(alias)
    first = first_enumerator(ty)
    if first:
        return f"{ty}::{first}"
    return f"{ty}()"


def struct(header: str, name: str):
    src = open(header).read()
    m = re.search(r"typedef struct " + name + r"\s*\{(.*?)\}\s*" + name + ";", src, re.S)
    if m:
        type_doc(src, r"typedef struct " + name + r"\b")
    else:
        # typedef struct NAME NAME; declared before, struct NAME { ... }; defined further
        m = re.search(r"^struct " + name + r"\s*\{(.*?)\};", src, re.S | re.M)
        type_doc(src, r"struct " + name + r"\s*\{") or type_doc(src, r"typedef struct " + name + r"\s+" + name + r"\s*;")
    body = re.sub(r"/\*(?!\*<).*?\*/", "", m.group(1), flags=re.S)
    docs = []
    body = re.sub(r"/\*\*<.*?\*/", lambda d: docs.append(comment_of(d.group(0))) or f"@{len(docs) - 1}@", body, flags=re.S)
    body = re.sub(r";\s*(@\d+@)", r" \1;", body)
    fields = []
    for part in body.split(";"):
        part = " ".join(part.split())
        several = re.match(r"([\w\s]*?\w)\s+(\w+(?:\s*,\s*\w+)+)\s*(@\d+@)?$", part)
        if several:
            # int x, y; one field per declarator, sharing the doc comment
            for fname in several.group(2).split(","):
                ty, _ = gen.ymir_type(several.group(1))
                doc = several.group(3)
                fields.append((fname.strip(), ty, default(ty), docs[int(doc.strip("@"))] if doc else ""))
            continue
        mm = re.match(r"(.*?)(\w+)\s*(?:\[(\w+)\])?\s*(?:@(\d+)@)?$", part)
        if not mm or not mm.group(1).strip():
            continue
        ctype, fname, arr, doc = mm.group(1).strip(), mm.group(2), mm.group(3), mm.group(4)
        ty, _ = gen.ymir_type(ctype)
        if arr:
            n = arr if arr.isdigit() else str(values(header, [arr], False)[arr])
            fty, fdef = f"[{ty}; {n}u32]", f"[{default(ty)}; {n}u32]"
        else:
            fty, fdef = ty, default(ty)
        fields.append((fname + "_" if fname in gen.KEYWORDS else fname, fty, fdef, docs[int(doc)] if doc else ""))
    # every field has a default, so the @data constructor builds the record with none of them, or any of them named
    print("@data")
    print(f"pub record {name} {{")
    for fname, fty, fdef, doc in fields:
        c = f" /**< {doc} */" if doc else ""
        print(f"    pub let mut {fname}: {fty} = {fdef};{c}")
    print("}")
    print()


if sys.argv[1] == "typedef":
    typedef(sys.argv[2], sys.argv[3])
elif sys.argv[1] == "struct":
    struct(sys.argv[2], sys.argv[3])
elif sys.argv[1] == "enum":
    enum(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else None)
else:
    defs(sys.argv[2], sys.argv[3], sys.argv[4])
