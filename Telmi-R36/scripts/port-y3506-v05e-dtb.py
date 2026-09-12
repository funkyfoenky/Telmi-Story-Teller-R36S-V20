#!/usr/bin/env python3
"""Y3506 V05e — panel4 DSI/PHY (probe Telmi) + panel stock + route VOP Y3506.

Lecon tests distants :
  - v05c / t-* : DSI panel4 probe → backlight puis OFF ~15s (crash probe panel)
  - v05d       : DSI stock → boot stable, backlight, mais pas de fb0/DRM (pas de probe)

v05e :
  - base panel4 Telmi (dsi: pclk, phy-names=dphy, px30-dsi-dphy) — comme v05c
  - panel stock complet (init, enable-gpios, timings) — comme v05c
  - route VOP → DSI comme stock Y3506 : vop endpoint@1 (pas @0)
  - pwm-backlight : periode stock (0x9c40) sur controleur panel4

Usage :
  python3 scripts/port-y3506-v05e-dtb.py
"""
from __future__ import annotations

import argparse
import importlib.util
import os
import re
import subprocess
import tempfile

_SCRIPT_V05C = os.path.join(os.path.dirname(__file__), "port-y3506-v05c-dtb.py")
_spec = importlib.util.spec_from_file_location("v05c", _SCRIPT_V05C)
_v05c = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_v05c)
_v05b = _v05c._v05b


def patch_vop_dsi_route_y3506(text: str) -> str:
    """Deplace la liaison VOP→DSI de endpoint@0 (Panel4 Telmi) vers @1 (stock Y3506)."""
    vop = _v05b.extract_node(text, "vop@ff460000")
    if not vop:
        raise SystemExit("vop@ff460000 missing")

    ep0 = _v05b.extract_node(vop, "endpoint@0")
    ep1 = _v05b.extract_node(vop, "endpoint@1")
    if not ep0 or not ep1:
        raise SystemExit("vop endpoint@0/@1 missing")

    def ref(block: str, prop: str) -> str:
        m = re.search(rf"{re.escape(prop)}\s*=\s*<([^>]+)>", block)
        if not m:
            raise SystemExit(f"{prop} missing in vop endpoint")
        return m.group(1).strip()

    dsi_remote = ref(ep0, "remote-endpoint")
    lvds_remote = ref(ep1, "remote-endpoint")
    ph_dsi = ref(ep0, "phandle")
    ph_lvds = ref(ep1, "phandle")

    ep2 = _v05b.extract_node(vop, "endpoint@2")
    rgb_remote = ref(ep2, "remote-endpoint") if ep2 else None
    ph_rgb = ref(ep2, "phandle") if ep2 else None

    # Stock Y3506 : endpoint@1 = DSI, @0 = LVDS, @2 = RGB
    new_ep0 = ep0
    new_ep0 = re.sub(
        r"remote-endpoint\s*=\s*<[^>]+>;",
        f"remote-endpoint = <{lvds_remote}>;",
        new_ep0,
        count=1,
    )
    new_ep0 = re.sub(
        r"phandle\s*=\s*<[^>]+>;",
        f"phandle = <{ph_lvds}>;",
        new_ep0,
        count=1,
    )

    new_ep1 = ep1
    new_ep1 = re.sub(
        r"remote-endpoint\s*=\s*<[^>]+>;",
        f"remote-endpoint = <{dsi_remote}>;",
        new_ep1,
        count=1,
    )
    new_ep1 = re.sub(
        r"phandle\s*=\s*<[^>]+>;",
        f"phandle = <{ph_dsi}>;",
        new_ep1,
        count=1,
    )

    new_vop = vop.replace(ep0, new_ep0, 1).replace(ep1, new_ep1, 1)

    # route-dsi connect doit rester sur le phandle DSI (= ex endpoint@0 / ep@1 apres swap)
    route_m = re.search(
        r"(route-dsi\s*\{[^}]*connect\s*=\s*)<[^>]+>(;)",
        text,
        re.S,
    )
    if route_m:
        new_text = text.replace(vop, new_vop, 1)
        if f"connect = <{ph_dsi}>" not in new_text:
            new_text = re.sub(
                r"(route-dsi\s*\{[^}]*connect\s*=\s*)<[^>]+>",
                rf"\g<1><{ph_dsi}>",
                new_text,
                count=1,
                flags=re.S,
            )
        return new_text

    return text.replace(vop, new_vop, 1)


def patch_backlight_pwm_period(text: str, stock_dts: str) -> str:
    """Periode PWM backlight stock (40000 ns) sur le pwm panel4."""
    bl = _v05b.extract_node(text, "backlight")
    stock_bl = _v05b.extract_node(stock_dts, "backlight")
    if not bl or not stock_bl:
        return text

    m = re.search(r"pwms\s*=\s*<([^>]+)>", stock_bl)
    if not m:
        return text
    stock_cells = [c.strip() for c in m.group(1).split()]
    if len(stock_cells) < 3:
        return text
    period = stock_cells[2]

    m2 = re.search(r"pwms\s*=\s*<([^>]+)>", bl)
    if not m2:
        return text
    base_cells = [c.strip() for c in m2.group(1).split()]
    if len(base_cells) < 3:
        return text
    base_cells[2] = period
    new_pwms = "pwms = <" + " ".join(base_cells) + ">;"
    new_bl = re.sub(r"pwms\s*=\s*<[^>]+>;", new_pwms, bl, count=1)
    return text.replace(bl, new_bl, 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="", help="default: boot/dtb/v30-panel4.dtb")
    ap.add_argument("--stock", default="", help="stock rk3326-r36s-linux-stock.dtb")
    ap.add_argument("--out", default="", help="default: boot/dtb/y3506-v05e.dtb")
    args = ap.parse_args()

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    base = args.base or os.path.join(root, "boot/dtb/v30-panel4.dtb")
    stock = args.stock or os.path.join(
        root,
        "dtb_backup/Y3506_V05_20251215 2601/rk3326-r36s-linux-stock.dtb",
    )
    out = args.out or os.path.join(root, "boot/dtb/y3506-v05e.dtb")

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
        text = open(base_dts, encoding="utf-8", errors="replace").read()
        stock_text = open(stock_dts, encoding="utf-8", errors="replace").read()

        text = _v05c.patch_panel_stock_full(text, stock, stock_text)
        text = patch_vop_dsi_route_y3506(text)
        text = patch_backlight_pwm_period(text, stock_text)
        text = re.sub(
            r'model = "[^"]+";',
            'model = "Telmi Y3506_V05e (panel4-DSI + route VOP stock)";',
            text,
            count=1,
        )

        dts_path = os.path.join(td, "out.dts")
        open(dts_path, "w", encoding="utf-8", newline="\n").write(text)
        os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
        subprocess.check_call(
            ["dtc", "-I", "dts", "-O", "dtb", "-o", out, dts_path],
            stderr=subprocess.DEVNULL,
        )

    print(f"OK {out} ({os.path.getsize(out)} bytes)")
    print("  dsi/phy : panel4 Telmi (dphy, pclk)")
    print("  panel   : stock complet (comme v05c)")
    print("  vop     : DSI sur endpoint@1 (comme stock Y3506)")
    print("  backlight pwm period : stock 0x9c40")


if __name__ == "__main__":
    main()
