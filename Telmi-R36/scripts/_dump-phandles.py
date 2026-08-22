#!/usr/bin/env python3
from pathlib import Path
import re
import sys

def path_of(dts: Path) -> dict[int, str]:
    text = dts.read_text()
    cur: list[str] = []
    mapp: dict[int, str] = {}
    for line in text.splitlines():
        m = re.match(r"\s*([A-Za-z0-9_,.@+\-]+)\s*\{", line)
        if m:
            cur.append(m.group(1))
        hm = re.search(r"phandle\s*=\s*<0x([0-9a-fA-F]+)>", line)
        if hm and cur:
            mapp[int(hm.group(1), 16)] = "/".join(cur)
        if re.match(r"\s*\};\s*$", line) and cur:
            cur.pop()
    return mapp

base = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
for name in ("p4", "v20"):
    m = path_of(base / f"{name}.dts")
    print("==", name)
    for h in (0x66, 0x97, 0xbf, 0xc3, 0x6f):
        print(f"  0x{h:x} -> {m.get(h, '?')}")
print("vol-down uV", 0x48058, "keyup", 0x1B7740, "vol-up", 0x3A98)
