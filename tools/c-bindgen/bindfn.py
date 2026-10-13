"""Turn the exported functions of an SDL3 header into Ymir extern declarations, with their docs.

usage: bindfn.py HEADER [--skip REGEX] [--only REGEX] [--skip-type REGEX]
"""
import re
import sys
import argparse

SCALARS = {
    "int": "i32", "unsigned int": "u32", "Uint8": "u8", "Sint8": "i8", "Uint16": "u16", "Sint16": "i16",
    "Uint32": "u32", "Sint32": "i32", "Uint64": "u64", "Sint64": "i64", "float": "f32", "double": "f64",
    "bool": "bool", "size_t": "usize", "char": "c8", "void": "void", "intptr_t": "isize", "uintptr_t": "usize",
    "long": "i64",
}

# Functions whose first pointer argument is changed by the call
MUTATORS = re.compile(r"^(SDL|IMG)_(Set|Show|Hide|Raise|Maximize|Minimize|Restore|Destroy|Sync|Flash|Update|"
                      r"Lock|Unlock|Clear|Fill|Blit|Flip|Add|Remove|Copy|Start|Stop|Warp|Capture|Free|Push|Flush|"
                      r"Reset|Enumerate|Scale|Premultiply|Convert|Duplicate|Save|Map|Write|Read|Load|Release|Unload|"
                      r"Close|Erase|Disable|Enable|Create|Pump|Peep|Wait|Poll|Register|Delete|free|realloc)")

# Functions taking a pointer they do not change although their name says otherwise
NOT_MUTATING = {"SDL_SetCursor"}

DOC_RE = re.compile(r"/\*\*(.*?)\*/\s*extern SDL_DECLSPEC (.*?)SDLCALL\s+(\w+)\s*\((.*?)\)\s*[^;]*;", re.S)


def ymir_type(ctype: str) -> tuple[str, bool]:
    """(ymir type, is a pointer to mutable data)"""
    t = ctype.replace("SDL_RESTRICT", "").replace("SDL_OUT_BYTECAP(len)", "").strip()
    t = re.sub(r"SDL_[A-Z_0-9]+\([^)]*\)", "", t).strip()
    stars = t.count("*")
    base = t.replace("*", " ").split()
    base = [w for w in base if w not in ("struct", "union", "enum")]
    consts = [i for i, w in enumerate(base) if w == "const"]
    words = [w for w in base if w != "const"]
    name = " ".join(words)
    name = SCALARS.get(name, name)
    if stars == 0:
        return name, False
    # a const before the first star qualifies the pointee (const char *, char const *)
    pointee_const = "const" in t.split("*")[0].split()
    ty = name
    for _ in range(stars):
        ty = f"*({ty})" if ty.startswith("*") else f"*{ty}"
    return ty, not pointee_const


def split_params(params: str) -> list[tuple[str, str]]:
    params = params.strip()
    if params in ("", "void"):
        return []
    out = []
    depth = 0
    cur = ""
    for ch in params:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    out.append(cur)
    res = []
    for p in out:
        p = " ".join(p.split())
        if p == "...":
            res.append(("...", "..."))
            continue
        m = re.match(r"(.*?)(\w+)(\[\])?$", p)
        ctype, name, arr = m.group(1), m.group(2), m.group(3)
        if arr:
            ctype += "*"
        res.append((ctype.strip(), name))
    return res


KEYWORDS = {"of", "expand", "throws", "mod", "in", "fn", "let", "self", "ref", "copy", "alias", "match", "is", "for", "pub", "prv", "prot", "cte", "use", "dcopy", "move", "loop", "break", "return", "if", "else", "while", "do", "with", "catch", "throw", "class", "record", "enum", "def", "macro", "trait", "impl", "over", "atomic", "scope", "exit", "success", "failure", "assert", "lazy", "sizeof", "typeof", "cast", "null", "true", "false", "aka", "extern", "template", "dg", "unsafe", "pragma", "version", "spawn", "future"}


def clean_doc(doc: str) -> list[str]:
    lines = []
    for line in doc.splitlines():
        line = re.sub(r"^\s*\*\s?", "", line).rstrip()
        lines.append(line)
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()

    text, params, returns = [], [], []
    cur = text
    for line in lines:
        s = line.strip()
        if s.startswith("\\param"):
            m = re.match(r"\\param\s+(\w+)\s*(.*)", s)
            params.append([m.group(1), m.group(2)])
            cur = params
        elif s.startswith("\\returns"):
            returns.append(s[len("\\returns"):].strip())
            cur = returns
        elif s.startswith("\\"):
            cur = None
        elif cur is params and s:
            params[-1][1] += " " + s
        elif cur is returns and s:
            returns[-1] += " " + s
        elif cur is text:
            text.append(line)
        else:
            cur = None if not s else cur
    while text and not text[-1].strip():
        text.pop()
    out = [" * " + l if l.strip() else " *" for l in text]
    out = [re.sub(r"`(\w+)\(\)`", r"\1()", l) for l in out]
    if params:
        out.append(" * @params:")
        for name, desc in params:
            out.append(f" *    - {name}: {desc}")
    if returns:
        out.append(" * @returns: " + " ".join(returns))
    return out


def wrap(line: str, width: int = 120) -> list[str]:
    if len(line) <= width:
        return [line]
    m = re.match(r"(\s*\*(?:\s+- \w+:| @returns:)?\s*)", line)
    prefix = m.group(1)
    cont = " *" + " " * (len(prefix) - 2 if "-" in prefix or "@" in prefix else 1)
    if "- " in prefix:
        cont = " *        "
    elif "@returns" in prefix:
        cont = " *   "
    words = line[len(prefix):].split(" ")
    out, cur = [], prefix
    for w in words:
        if len(cur) + len(w) + 1 > width and cur.strip(" *"):
            out.append(cur.rstrip())
            cur = cont + w
        else:
            cur = cur + ("" if cur.endswith(" ") or cur == prefix and prefix.endswith(" ") else " ") + w
    out.append(cur.rstrip())
    return out


def convert(name: str, ret: str, params: str) -> str:
    rty, rmut = ymir_type(ret.replace("SDL_MALLOC", "").strip())
    ps = []
    for i, (ctype, pname) in enumerate(split_params(params)):
        if ctype == "...":
            return None
        ty, mut = ymir_type(ctype)
        if pname in KEYWORDS:
            pname = pname + "_"
        prefix = ""
        if ty.startswith("*") and mut:
            # an output pointer, or the object a mutator changes
            if ty in ("*c8",) and "const" in ctype:
                prefix = ""
            elif name in NOT_MUTATING:
                prefix = ""
            elif i > 0 or MUTATORS.match(name) or ty in ("*i32", "*u32", "*f32", "*bool", "*usize", "*u64", "*i64", "*u8", "*u16", "*f64") or ty.startswith("**") or ty.startswith("*(*"):
                prefix = "dmut "
        ps.append(f"{prefix}{pname}: {ty}")
    sig = f"pub extern (C) fn {name}({', '.join(ps)})"
    if rty != "void":
        if rty.startswith("*") and rmut:
            sig += f"-> dmut {rty}"
        else:
            sig += f"-> {rty}"
    return sig + ";"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("header")
    ap.add_argument("--skip", default=None)
    ap.add_argument("--only", default=None)
    ap.add_argument("--skip-type", default=None, help="skip the functions whose signature names a matching type")
    a = ap.parse_args()
    src = open(a.header).read()
    for m in DOC_RE.finditer(src):
        doc, ret, name, params = m.groups()
        if "/**" in doc:
            doc = doc[doc.rindex("/**") + 3:]
        if a.skip and re.search(a.skip, name):
            continue
        if a.only and not re.search(a.only, name):
            continue
        if a.skip_type and re.search(a.skip_type, ret + params):
            continue
        decl = convert(name, " ".join(ret.split()), params)
        if decl is None:
            print(f"// {name} is variadic, not bound\n", file=sys.stderr)
            continue
        print("/**")
        for l in clean_doc(doc):
            for w in wrap(l):
                print(w)
        print(" */")
        print(decl)
        print()


if __name__ == "__main__":
    main()
