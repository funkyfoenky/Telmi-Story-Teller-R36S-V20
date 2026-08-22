#!/usr/bin/env python3
"""Resolve panel reset/backlight phandles in decompiled DTS files."""
from __future__ import annotations

import re
import sys
from pathlib import Path


def phandle_map(text: str) -> dict[int, str]:
    cur: list[str] = []
    path_of: dict[int, str] = {}
    for line in text.splitlines():
        m = re.match(r"\s*([A-Za-z0-9_,.@+\-]+)\s*\{", line)
        if m:
            cur.append(m.group(1))
        hm = re.search(r"phandle\s*=\s*<0x([0-9a-fA-F]+)>", line)
        if hm and cur:
            path_of[int(hm.group(1), 16)] = "/".join(cur)
        # close nodes: lines that are only whitespace + };
        if re.match(r"\s*\};\s*$", line) and cur:
            cur.pop()
    return path_of


def panel_block(text: str) -> str:
    m = re.search(r"panel@0\s*\{", text)
    if not m:
        return ""
    j = text.find("{", m.start())
    depth = 0
    k = j
    while k < len(text):
        if text[k] == "{":
            depth += 1
        elif text[k] == "}":
            depth -= 1
            if depth == 0:
                return text[j + 1 : k]
        k += 1
    return ""


def describe(label: str, dts: Path) -> None:
    text = dts.read_text(errors="replace")
    pm = phandle_map(text)
    blk = panel_block(text)
    print(f"=== {label} ===")
    for prop in ("reset-gpios", "enable-gpios"):
        rg = re.search(
            rf"{prop}\s*=\s*<0x([0-9a-fA-F]+)\s+0x([0-9a-fA-F]+)\s+0x([0-9a-fA-F]+)>",
            blk,
        )
        if not rg:
            continue
        ctl = int(rg.group(1), 16)
        pin = int(rg.group(2), 16)
        flags = int(rg.group(3), 16)
        print(f"{prop}: ctl=0x{ctl:x} ({pm.get(ctl, '?')}) pin={pin} flags={flags}")
    bl = re.search(r"backlight\s*=\s*<0x([0-9a-fA-F]+)>", blk)
    if bl:
        b = int(bl.group(1), 16)
        print(f"backlight: 0x{b:x} ({pm.get(b, '?')})")
    ps = re.search(r"power-supply\s*=\s*<0x([0-9a-fA-F]+)>", blk)
    if ps:
        p = int(ps.group(1), 16)
        print(f"power-supply: 0x{p:x} ({pm.get(p, '?')})")


def main() -> int:
    pairs = sys.argv[1:] or [
        "v20:/tmp/panel-port/v20.dts",
        "p4:/tmp/panel-port/p4.dts",
        "p5:/tmp/panel-port/p5.dts",
    ]
    for item in pairs:
        label, path = item.split(":", 1)
        describe(label, Path(path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
