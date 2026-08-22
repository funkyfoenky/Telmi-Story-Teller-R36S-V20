#!/usr/bin/env python3
"""Extract panel@0 node from a .dts for comparison / porting."""
import re
import sys
from pathlib import Path


def extract_panel(text: str) -> str | None:
    m = re.search(r"panel@0\s*\{", text)
    if not m:
        return None
    i = m.start()
    j = text.find("{", i)
    depth = 0
    k = j
    while k < len(text):
        if text[k] == "{":
            depth += 1
        elif text[k] == "}":
            depth -= 1
            if depth == 0:
                end = k + 1
                if end < len(text) and text[end] == ";":
                    end += 1
                return text[i:end]
        k += 1
    return None


KEYS = (
    "compatible",
    "panel-init",
    "panel-exit",
    "dsi,",
    "width",
    "height",
    "reset",
    "backlight",
    "timing",
    "clock-frequency",
    "hactive",
    "vactive",
    "rotate",
    "rockchip,lane",
    "enable-gpios",
    "reset-gpios",
)


def main() -> int:
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} file.dts [out.frag]", file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    text = path.read_text(errors="replace")
    blk = extract_panel(text)
    if not blk:
        print(f"No panel@0 in {path}", file=sys.stderr)
        return 1
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else path.with_suffix(".panel.dtsfrag")
    out.write_text(blk)
    print(f"=== {path.name} panel@0 ({len(blk)} chars) -> {out} ===")
    for line in blk.splitlines():
        if any(k in line for k in KEYS):
            print(line[:180])
    print("--- head ---")
    print("\n".join(blk.splitlines()[:45]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
