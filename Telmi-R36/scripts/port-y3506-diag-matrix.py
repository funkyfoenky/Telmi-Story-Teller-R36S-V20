#!/usr/bin/env python3
"""Matrice DTB diagnostic Y3506 — isole init / timings / panel / headless.

Genere sous boot/dtb/ :
  y3506-bootdiag.dtb   base panel4, DSI disabled, uboot-charge OFF
  y3506-t-panel4.dtb   = v30-panel4 (temoin)
  y3506-t-init.dtb     panel4 + init DarkOS seulement (timings panel4)
  y3506-t-timings.dtb  panel4 + timings DarkOS seulement (init panel4)

Usage :
  python3 scripts/port-y3506-diag-matrix.py \\
    --base boot/dtb/v30-panel4.dtb \\
    --y3506 "dtb_backup/Y3506_V05_20251215 2601/rk3326-r36s-linux.dtb" \\
    --outdir boot/dtb
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import tempfile


def run_dtc(args, **kw):
    subprocess.check_call(["dtc"] + args, **kw)


def extract_node(text: str, want: str) -> str | None:
    lines = text.splitlines()
    pat = re.compile(r"^(\s*)" + re.escape(want) + r"\s*\{")
    start = None
    for i, line in enumerate(lines):
        if pat.match(line):
            start = i
            break
    if start is None:
        return None
    depth = 0
    out = []
    for line in lines[start:]:
        out.append(line)
        depth += line.count("{") - line.count("}")
        if depth == 0:
            break
    return "\n".join(out)


def replace_node(text: str, want: str, new_block: str) -> str:
    old = extract_node(text, want)
    if old is None:
        raise SystemExit(f"node {want} not found")
    return text.replace(old, new_block, 1)


def set_prop_line(block: str, prop: str, value_line: str) -> str:
    pat = re.compile(rf"^(\s*){re.escape(prop)}\s*=\s*.*;\s*$", re.M)
    if pat.search(block):
        return pat.sub(lambda mm: mm.group(1) + value_line, block, count=1)
    # insert after opening brace
    lines = block.splitlines()
    indent = re.match(r"^(\s*)", lines[1] if len(lines) > 1 else "\t").group(1)
    lines.insert(1, indent + value_line)
    return "\n".join(lines)


def cells_to_bytes(cells_text: str) -> bytes:
    cells = [
        int(x, 16) if x.startswith("0x") else int(x)
        for x in re.findall(r"0x[0-9a-fA-F]+|\d+", cells_text)
    ]
    return b"".join(c.to_bytes(4, "big") for c in cells)


def byte_array_to_dts(raw: bytes) -> str:
    return "[" + " ".join(f"{b:02x}" for b in raw) + "]"


def extract_raw_init(dtb_path: str, y_dts_panel: str) -> bytes:
    try:
        out = subprocess.check_output(
            ["fdtget", "-t", "bx", dtb_path, "/dsi@ff450000/panel@0", "panel-init-sequence"],
            stderr=subprocess.DEVNULL,
            text=True,
        )
        return bytes(int(x, 16) for x in out.split())
    except (subprocess.CalledProcessError, FileNotFoundError):
        m = re.search(r"panel-init-sequence\s*=\s*<([^>]+)>", y_dts_panel)
        if m:
            return cells_to_bytes(m.group(1))
        m = re.search(r"panel-init-sequence\s*=\s*\[([^\]]+)\]", y_dts_panel)
        if not m:
            raise SystemExit("init sequence not found")
        return bytes(int(x, 16) for x in m.group(1).split())


def set_model(text: str, model: str) -> str:
    return re.sub(r'model = "[^"]+";', f'model = "{model}";', text, count=1)


def compile_dts(text: str, out_dtb: str) -> None:
    with tempfile.TemporaryDirectory() as td:
        p = os.path.join(td, "x.dts")
        open(p, "w", encoding="utf-8", newline="\n").write(text)
        run_dtc(["-I", "dts", "-O", "dtb", "-o", out_dtb, p], stderr=subprocess.DEVNULL)


def patch_init_only(base: str, init_bytes: bytes) -> str:
    panel = extract_node(base, "panel@0")
    if not panel:
        raise SystemExit("panel@0 missing")
    init_dts = byte_array_to_dts(init_bytes)
    new = re.sub(
        r"panel-init-sequence = \[[^\]]+\];",
        f"panel-init-sequence = {init_dts};",
        panel,
        count=1,
    )
    if "panel-init-sequence = [" not in new:
        new = re.sub(
            r"panel-init-sequence = <[^>]+>;",
            f"panel-init-sequence = {init_dts};",
            panel,
            count=1,
        )
    return replace_node(base, "panel@0", new)


def patch_timings_only(base: str, y_panel: str) -> str:
    timing_src = extract_node(y_panel, "60Hz")
    if not timing_src:
        raise SystemExit("60Hz missing")

    def tprop(name: str, default: str | None = None) -> str:
        m = re.search(rf"{re.escape(name)}\s*=\s*<([^>]+)>", timing_src)
        if not m:
            if default is not None:
                return default
            raise SystemExit(f"missing {name}")
        return m.group(1).strip()

    panel = extract_node(base, "panel@0")
    timing0 = extract_node(panel or "", "timing0")
    if not panel or not timing0:
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
        default = "0x00" if prop == "pixelclk-active" else None
        val = tprop(prop, default)
        cell = val if val.startswith("<") else f"<{val}>"
        tnew = set_prop_line(tnew, prop, f"{prop} = {cell};")
    panel2 = panel.replace(timing0, tnew, 1)
    return replace_node(base, "panel@0", panel2)


def patch_bootdiag(base: str) -> str:
    """DSI off + pas d'extinction charge U-Boot — but : Linux headless + log BOOT."""
    text = base
    dsi = extract_node(text, "dsi@ff450000")
    if not dsi:
        raise SystemExit("dsi@ff450000 missing")
    if 'status = "okay"' in dsi:
        dsi2 = dsi.replace('status = "okay";', 'status = "disabled";', 1)
    elif "status =" not in dsi.split("{", 1)[1][:200]:
        dsi2 = set_prop_line(dsi, "status", 'status = "disabled";')
    else:
        dsi2 = re.sub(r'status = "[^"]+";', 'status = "disabled";', dsi, count=1)
    text = replace_node(text, "dsi@ff450000", dsi2)

    ch = extract_node(text, "charge-animation")
    if ch:
        ch2 = ch
        if "rockchip,uboot-charge-on" in ch2:
            ch2 = set_prop_line(
                ch2, "rockchip,uboot-charge-on", "rockchip,uboot-charge-on = <0x00>;"
            )
        else:
            ch2 = set_prop_line(
                ch2, "rockchip,uboot-charge-on", "rockchip,uboot-charge-on = <0x00>;"
            )
        # evite sortie charge auto si present
        if "rockchip,uboot-exit-charge-auto" in ch2:
            ch2 = set_prop_line(
                ch2,
                "rockchip,uboot-exit-charge-auto",
                "rockchip,uboot-exit-charge-auto = <0x00>;",
            )
        text = replace_node(text, "charge-animation", ch2)
    return text


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--y3506", required=True)
    ap.add_argument("--outdir", required=True)
    args = ap.parse_args()
    os.makedirs(args.outdir, exist_ok=True)

    with tempfile.TemporaryDirectory() as td:
        base_dts = os.path.join(td, "base.dts")
        y_dts = os.path.join(td, "y.dts")
        run_dtc(["-I", "dtb", "-O", "dts", "-o", base_dts, args.base], stderr=subprocess.DEVNULL)
        run_dtc(["-I", "dtb", "-O", "dts", "-o", y_dts, args.y3506], stderr=subprocess.DEVNULL)
        base = open(base_dts, encoding="utf-8", errors="replace").read()
        y3506 = open(y_dts, encoding="utf-8", errors="replace").read()
        y_panel = extract_node(y3506, "panel@0") or ""
        init_bytes = extract_raw_init(args.y3506, y_panel)

        outs = []

        # 1) temoin panel4
        p4 = os.path.join(args.outdir, "y3506-t-panel4.dtb")
        shutil.copy2(args.base, p4)
        outs.append(("y3506-t-panel4.dtb", "temoin = v30-panel4 stock"))

        # 2) init only
        t = set_model(patch_init_only(base, init_bytes), "Telmi Y3506 diag: init DarkOS only")
        out = os.path.join(args.outdir, "y3506-t-init.dtb")
        compile_dts(t, out)
        outs.append(("y3506-t-init.dtb", "panel4 timings + init DarkOS"))

        # 3) timings only
        t = set_model(patch_timings_only(base, y_panel), "Telmi Y3506 diag: timings DarkOS only")
        out = os.path.join(args.outdir, "y3506-t-timings.dtb")
        compile_dts(t, out)
        outs.append(("y3506-t-timings.dtb", "panel4 init + timings DarkOS 40MHz"))

        # 4) bootdiag headless
        t = set_model(patch_bootdiag(base), "Telmi Y3506 bootdiag (DSI off)")
        out = os.path.join(args.outdir, "y3506-bootdiag.dtb")
        compile_dts(t, out)
        outs.append(("y3506-bootdiag.dtb", "DSI disabled + uboot-charge off"))

        print("OK matrice Y3506 :")
        for name, desc in outs:
            path = os.path.join(args.outdir, name)
            print(f"  {name:22} {os.path.getsize(path):6} o  — {desc}")


if __name__ == "__main__":
    main()
