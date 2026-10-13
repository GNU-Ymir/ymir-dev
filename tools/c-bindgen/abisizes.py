"""cte asserts of the sizes of the records and enums of a binding, as the C compiler lays them out.

usage: abisizes.py INCLUDE... -- FILE.yr...   (INCLUDE: the C headers, e.g. SDL3/SDL.h)
"""
import os
import re
import subprocess
import sys
import tempfile

sep = sys.argv.index("--")
includes, files = sys.argv[1:sep], sys.argv[sep + 1:]

types = []
for f in files:
    src = open(f).read()
    for m in re.finditer(r"^pub record (\w+) \{\n", src, re.M):
        types.append(m.group(1))
    for m in re.finditer(r"^pub enum (\w+)\n", src, re.M):
        types.append(m.group(1))

c = "".join(f"#include <{i}>\n" for i in includes) + "#include <stdio.h>\nint main(void){\n"
for t in types:
    c += f'printf("{t} %zu\\n", sizeof({t}));\n'
c += "return 0;}\n"
with tempfile.TemporaryDirectory() as d:
    open(os.path.join(d, "s.c"), "w").write(c)
    subprocess.run(["gcc", os.path.join(d, "s.c"), "-o", os.path.join(d, "s"), "-w"], check=True)
    out = subprocess.run([os.path.join(d, "s")], check=True, capture_output=True, text=True).stdout

for line in out.splitlines():
    t, n = line.split()
    print(f"    cte assert ({t}::size == {n});")
