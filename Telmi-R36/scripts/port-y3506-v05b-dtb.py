#!/usr/bin/env python3
"""Y3506 V05b — port panel minimal sur base Telmi v30-panel4 (5.10).

Lecon v05 (echec distant : icone batterie U-Boot 15s puis OFF) :
  - trop de diffs d'un coup (enable-gpios gpio1.18, SD, volume, base v20)
  - enable-gpios absent du Panel4 Telmi : risque hang / conflit

Strategie v05b (un seul objectif : image a l'ecran) :
  - base = boot/dtb/v30-panel4.dtb (elida + reset gpio3.16 deja OK sur 5.10)
  - remplace UNIQUEMENT panel-init-sequence + timings 60 Hz depuis DarkOS
  - PAS enable-gpios, PAS patch SD, PAS volume keys
"""
from __future__ import annotations

import argparse
import os
import re
import struct
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
    raise SystemExit(f"prop {prop} not found in block")


def remove_prop(block: str, prop: str) -> str:
    return re.sub(rf"^\s*{re.escape(prop)}\s*=\s*.*;\s*\n", "", block, flags=re.M)


def cells_to_bytes(cells_text: str) -> bytes:
    cells = [
        int(x, 16) if x.startswith("0x") else int(x)
        for x in re.findall(r"0x[0-9a-fA-F]+|\d+", cells_text)
    ]
    return b"".join(c.to_bytes(4, "big") for c in cells)


def byte_array_to_dts(raw: bytes) -> str:
    return "[" + " ".join(f"{b:02x}" for b in raw) + "]"


def extract_init_bytes(panel_src: str) -> bytes:
    m = re.search(r"panel-init-sequence\s*=\s*<([^>]+)>", panel_src)
    if m:
        return cells_to_bytes(m.group(1))
    m = re.search(r"panel-init-sequence\s*=\s*\[([^\]]+)\]", panel_src)
    if not m:
        raise SystemExit("panel-init-sequence not found in DarkOS panel")
    return bytes(int(x, 16) for x in m.group(1).split())


def extract_raw_prop_from_dtb(dtb_path: str, node_path: str, prop: str) -> bytes | None:
    """Prefer fdtget raw bytes when available (exact DarkOS property)."""
    try:
        out = subprocess.check_output(
            ["fdtget", "-t", "bx", dtb_path, node_path, prop],
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    parts = out.split()
    if not parts:
        return None
    return bytes(int(x, 16) for x in parts)


def patch_panel(base: str, y3506: str, y3506_dtb: str) -> str:
    src = extract_node(y3506, "panel@0")
    dst = extract_node(base, "panel@0")
    if not src or not dst:
        raise SystemExit("panel@0 missing")

    raw = extract_raw_prop_from_dtb(
        y3506_dtb, "/dsi@ff450000/panel@0", "panel-init-sequence"
    )
    if raw is None:
        raw = extract_init_bytes(src)
    if len(raw) < 32:
        raise SystemExit(f"init sequence too short ({len(raw)} bytes)")
    # Sanity : NT35510-like page select
    if raw[0:4] != bytes([0x39, 0x00, 0x06, 0xF0]) and raw[0:3] != bytes(
        [0x39, 0x00, 0x05]
    ):
        # still accept ; log hint
        print(f"WARN: init head = {raw[:8].hex(' ')} (attendu 39 00 06 f0 …)")

    init_dts = byte_array_to_dts(raw)

    timing_src = extract_node(src, "60Hz")
    if not timing_src:
        raise SystemExit("Y3506 60Hz timings missing")

    def tprop(name: str, default: str | None = None) -> str:
        m = re.search(rf"{re.escape(name)}\s*=\s*<([^>]+)>", timing_src)
        if not m:
            if default is not None:
                return default
            raise SystemExit(f"timing prop {name} missing")
        return m.group(1).strip()

    new = dst
    # S'assurer compatible panel Telmi 5.10 (deja le cas sur panel4)
    new = re.sub(
        r'compatible = "[^"]+";',
        'compatible = "elida,kd35t133\\0simple-panel-dsi";',
        new,
        count=1,
    )
    # Jamais d'enable-gpios sur ce port (cause suspecte v05)
    new = remove_prop(new, "enable-gpios")
    new = remove_prop(new, "led-red-gpios")
    new = remove_prop(new, "led-blue1-gpios")

    # Delais : garder ceux Panel4 (prouves 5.10), sauf reset un peu plus court DarkOS
    # Panel4 : prepare 0x14, reset 0x96, enable 0x78 — on garde
    # reset-gpios deja gpio3.16 sur panel4 (= Y3506)

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

    # Exit sequence DarkOS (identique Panel4 Telmi deja)
    new = set_prop_line(new, "panel-exit-sequence", "panel-exit-sequence = <0x5140128 0x50a0110>;")

    timing0 = extract_node(new, "timing0")
    if not timing0:
        raise SystemExit("base timing0 missing")
    tnew = timing0
    tmap = {
        "clock-frequency": tprop("clock-frequency"),
        "hactive": tprop("hactive"),
        "vactive": tprop("vactive"),
        "hfront-porch": tprop("hfront-porch"),
        "hback-porch": tprop("hback-porch"),
        "vfront-porch": tprop("vfront-porch"),
        "vback-porch": tprop("vback-porch"),
        "hsync-len": tprop("hsync-len"),
        "vsync-len": tprop("vsync-len"),
        "pixelclk-active": tprop("pixelclk-active", "0x00"),
    }
    for prop, val in tmap.items():
        cell = val if val.startswith("<") else f"<{val}>"
        tnew = set_prop_line(tnew, prop, f"{prop} = {cell};")
    # DarkOS 60Hz : de-active / hsync / vsync deja 0
    new = new.replace(timing0, tnew, 1)

    return replace_node(base, "panel@0", new)


def patch_model(text: str) -> str:
    return re.sub(
        r'model = "[^"]+";',
        'model = "Telmi Y3506_V05b (panel4-base + DarkOS init)";',
        text,
        count=1,
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--base",
        required=True,
        help="Telmi boot/dtb/v30-panel4.dtb (skeleton 5.10 prouve)",
    )
    ap.add_argument("--y3506", required=True, help="DarkOS rk3326-r36s-linux.dtb")
    ap.add_argument("--out", required=True, help="Output y3506-v05b.dtb")
    ap.add_argument("--keep-dts", default="", help="Optional patched DTS path")
    args = ap.parse_args()

    with tempfile.TemporaryDirectory() as td:
        base_dts = os.path.join(td, "base.dts")
        y_dts = os.path.join(td, "y3506.dts")
        run_dtc(
            ["-I", "dtb", "-O", "dts", "-o", base_dts, args.base],
            stderr=subprocess.DEVNULL,
        )
        run_dtc(
            ["-I", "dtb", "-O", "dts", "-o", y_dts, args.y3506],
            stderr=subprocess.DEVNULL,
        )
        base = open(base_dts, encoding="utf-8", errors="replace").read()
        y3506 = open(y_dts, encoding="utf-8", errors="replace").read()

        patched = patch_panel(base, y3506, args.y3506)
        patched = patch_model(patched)

        # Filet : aucun enable-gpios residuel sur panel
        panel = extract_node(patched, "panel@0") or ""
        if "enable-gpios" in panel:
            raise SystemExit("enable-gpios still present — abort")

        dts_path = os.path.join(td, "patched.dts")
        open(dts_path, "w", encoding="utf-8", newline="\n").write(patched)
        if args.keep_dts:
            os.makedirs(os.path.dirname(args.keep_dts) or ".", exist_ok=True)
            open(args.keep_dts, "w", encoding="utf-8", newline="\n").write(patched)

        os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
        # Quiet warnings like original ports
        run_dtc(
            ["-I", "dts", "-O", "dtb", "-o", args.out, dts_path],
            stderr=subprocess.DEVNULL,
        )
        size = os.path.getsize(args.out)

        # Resume pour le testeur
        init_m = re.search(r"panel-init-sequence = \[([0-9a-f ]{24})", patched)
        head = init_m.group(1) if init_m else "?"
        print(f"OK {args.out} ({size} bytes)")
        print(f"  base     : {os.path.basename(args.base)}")
        print(f"  init head: {head}…")
        print("  enable-gpios: ABSENT")
        print("  SD/volume : inchanges (ceux de panel4)")


if __name__ == "__main__":
    main()
