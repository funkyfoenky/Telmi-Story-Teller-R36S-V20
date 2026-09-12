#!/usr/bin/env python3
"""Y3506 V05c — panel4 base + panel STOCK complet (init + enable-gpios + LED).

Lecon stock rk3326-r36s-linux-stock.dtb :
  - identique au backup DarkOS sauf otg_switch-supply sur chargeur
  - panel-init v05b deja correct (420 o identiques)
  - stock a enable-gpios gpio1.18 + led-red/blue — retires a tort en v05b
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import tempfile

# Reuse v05b helpers
import importlib.util

_SCRIPT = os.path.join(os.path.dirname(__file__), "port-y3506-v05b-dtb.py")
_spec = importlib.util.spec_from_file_location("v05b", _SCRIPT)
_v05b = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_v05b)


def set_prop_line(block: str, prop: str, value_line: str) -> str:
    pat = re.compile(rf"^(\s*){re.escape(prop)}\s*=\s*.*;\s*$", re.M)
    if pat.search(block):
        return pat.sub(lambda mm: mm.group(1) + value_line, block, count=1)
    lines = block.splitlines()
    indent = re.match(r"^(\s*)", lines[1] if len(lines) > 1 else "\t\t").group(1)
    insert_at = 1
    for i, line in enumerate(lines[1:], 1):
        if line.strip().startswith("compatible"):
            insert_at = i + 1
            break
        insert_at = i
    lines.insert(insert_at, indent + value_line)
    return "\n".join(lines)


def patch_panel_stock_full(base: str, stock_dtb: str, stock_dts: str) -> str:
    src = _v05b.extract_node(stock_dts, "panel@0")
    dst = _v05b.extract_node(base, "panel@0")
    if not src or not dst:
        raise SystemExit("panel@0 missing")

    raw = _v05b.extract_raw_prop_from_dtb(
        stock_dtb, "/dsi@ff450000/panel@0", "panel-init-sequence"
    )
    if raw is None:
        raw = _v05b.extract_init_bytes(src)
    init_dts = _v05b.byte_array_to_dts(raw)

    timing_src = _v05b.extract_node(src, "60Hz")
    if not timing_src:
        raise SystemExit("60Hz missing")

    def tprop(name: str, default: str | None = None) -> str:
        m = re.search(rf"{re.escape(name)}\s*=\s*<([^>]+)>", timing_src)
        if not m:
            if default is not None:
                return default
            raise SystemExit(f"missing {name}")
        return m.group(1).strip()

    new = dst
    new = re.sub(
        r'compatible = "[^"]+";',
        'compatible = "elida,kd35t133\\0simple-panel-dsi";',
        new,
        count=1,
    )
    # Phandles panel4 Telmi 5.10 (gpio0=0x5c gpio1=0xc9 gpio3=0x66)
    props = {
        "enable-gpios": "<0xc9 0x12 0x01>",
        "reset-gpios": "<0x66 0x10 0x01>",
        "led-red-gpios": "<0x5c 0x05 0x00>",
        "led-blue1-gpios": "<0x5c 0x00 0x00>",
        "prepare-delay-ms": "<0x64>",
        "reset-delay-ms": "<0x32>",
        "init-delay-ms": "<0x14>",
        "enable-delay-ms": "<0xc8>",
        "disable-delay-ms": "<0x32>",
        "unprepare-delay-ms": "<0x14>",
        "width-mm": "<0x47>",
        "height-mm": "<0x47>",
        "panel-exit-sequence": "<0x5140128 0x50a0110>",
    }
    for prop, val in props.items():
        new = set_prop_line(new, prop, f"{prop} = {val};")

    new = re.sub(
        r"panel-init-sequence = \[[^\]]+\];",
        f"panel-init-sequence = {init_dts};",
        new,
        count=1,
    )
    if "panel-init-sequence = [" not in new:
        new = re.sub(
            r"panel-init-sequence = <[^>]+>;",
            f"panel-init-sequence = {init_dts};",
            new,
            count=1,
        )

    timing0 = _v05b.extract_node(new, "timing0")
    if not timing0:
        raise SystemExit("timing0 missing")
    tnew = timing0
    for prop in (
        "clock-frequency",
        "hactive",
        "vactive",
        "hfront-porch",
        "hback-porch",
        "vfront-porch",
        "vback-porch",
        "hsync-len",
        "vsync-len",
        "pixelclk-active",
    ):
        val = tprop(prop, "0x00" if prop == "pixelclk-active" else None)
        cell = val if val.startswith("<") else f"<{val}>"
        tnew = set_prop_line(tnew, prop, f"{prop} = {cell};")
    new = new.replace(timing0, tnew, 1)

    return _v05b.replace_node(base, "panel@0", new)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="", help="default: boot/dtb/v30-panel4.dtb")
    ap.add_argument("--stock", default="", help="default: stock dtb path")
    ap.add_argument("--out", default="", help="default: boot/dtb/y3506-v05c.dtb")
    args = ap.parse_args()

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    base = args.base or os.path.join(root, "boot/dtb/v30-panel4.dtb")
    stock = args.stock or os.path.join(
        root,
        "dtb_backup/Y3506_V05_20251215 2601/rk3326-r36s-linux-stock.dtb",
    )
    out = args.out or os.path.join(root, "boot/dtb/y3506-v05c.dtb")

    with tempfile.TemporaryDirectory() as td:
        base_dts = os.path.join(td, "base.dts")
        stock_dts = os.path.join(td, "stock.dts")
        subprocess.check_call(
            ["dtc", "-I", "dtb", "-O", "dts", "-o", base_dts, base],
            stderr=subprocess.DEVNULL,
        )
        subprocess.check_call(
            ["dtc", "-I", "dtb", "-O", "dts", "-o", stock_dts, stock],
            stderr=subprocess.DEVNULL,
        )
        base_text = open(base_dts, encoding="utf-8", errors="replace").read()
        stock_text = open(stock_dts, encoding="utf-8", errors="replace").read()

        patched = patch_panel_stock_full(base_text, stock, stock_text)
        patched = re.sub(
            r'model = "[^"]+";',
            'model = "Telmi Y3506_V05c (panel stock complet)";',
            patched,
            count=1,
        )

        dts_path = os.path.join(td, "patched.dts")
        open(dts_path, "w", encoding="utf-8", newline="\n").write(patched)
        os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
        subprocess.check_call(
            ["dtc", "-I", "dts", "-O", "dtb", "-o", out, dts_path],
            stderr=subprocess.DEVNULL,
        )
        print(f"OK {out} ({os.path.getsize(out)} bytes)")
        print("  enable-gpios gpio1.18 + led-red/blue (comme stock)")
        print("  init/timings = stock")


if __name__ == "__main__":
    main()
