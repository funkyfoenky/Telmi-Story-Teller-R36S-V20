#!/usr/bin/env python3
"""Y3506 V05d — panel4 Telmi + bloc DSI/PHY stock + panel stock (v05c).

Lecon tests distants :
  - bootdiag OK sans MIPI
  - v05c / t-panel4 / t-init : backlight ou batterie puis OFF ~15s
  - panel seul (init, enable-gpios) insuffisant

v05d : aligne le sous-systeme DSI sur le stock Y3506 :
  - video-phy : #clock-cells + clock-names stock (phandles panel4 conserves)
  - dsi@ff450000 : clocks pclk+hs_clk, phy-names mipi_dphy
  - panel@0 : identique v05c (init/timings/enable-gpios stock)

Usage :
  python3 scripts/port-y3506-v05d-dtb.py
"""
from __future__ import annotations

import argparse
import importlib.util
import os
import re
import subprocess
import tempfile

_SCRIPT_V05C = os.path.join(os.path.dirname(__file__), "port-y3506-v05c-dtb.py")
_SCRIPT_V05B = os.path.join(os.path.dirname(__file__), "port-y3506-v05b-dtb.py")
_spec_b = importlib.util.spec_from_file_location("v05b", _SCRIPT_V05B)
_v05b = importlib.util.module_from_spec(_spec_b)
_spec_b.loader.exec_module(_v05b)

_spec = importlib.util.spec_from_file_location("v05c", _SCRIPT_V05C)
_v05c = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_v05c)


def set_or_replace_prop(block: str, prop: str, value_line: str) -> str:
    pat = re.compile(rf"^(\s*){re.escape(prop)}\s*=\s*.*;\s*$", re.M)
    if pat.search(block):
        return pat.sub(lambda m: m.group(1) + value_line, block, count=1)
    lines = block.splitlines()
    indent = re.match(r"^(\s*)", lines[0]).group(1) + "\t"
    lines.insert(1, indent + value_line)
    return "\n".join(lines)


def remove_prop(block: str, prop: str) -> str:
    return re.sub(rf"^\s*{re.escape(prop)}\s*=\s*.*;\s*\n", "", block, flags=re.M)


def patch_phy_stock_style(base: str, stock: str) -> str:
    """phy@ff2e0000 panel4 -> fournisseur hs_clk comme stock (garde phandles panel4)."""
    phy = _v05b.extract_node(base, "phy@ff2e0000")
    if not phy:
        raise SystemExit("phy@ff2e0000 missing in base")
    stock_phy = _v05b.extract_node(stock, "video-phy@ff2e0000")
    if not stock_phy:
        stock_phy = _v05b.extract_node(stock, "phy@ff2e0000")
    if not stock_phy:
        raise SystemExit("video-phy@ff2e0000 missing in stock")

    new = phy
    new = re.sub(
        r'compatible = "[^"]+";',
        'compatible = "rockchip,px30-video-phy";',
        new,
        count=1,
    )
    new = remove_prop(new, "reg-names")
    new = set_or_replace_prop(new, "clock-names", 'clock-names = "ref\\0pclk_phy\\0pclk_host";')
    new = set_or_replace_prop(new, "#clock-cells", "#clock-cells = <0x00>;")
    new = set_or_replace_prop(new, "reset-names", 'reset-names = "rst";')
    return _v05b.replace_node(base, "phy@ff2e0000", new)


def patch_dsi_stock_style(base: str) -> str:
    """dsi panel4 -> clocks hs_clk + phy-names mipi_dphy (phandle phy panel4)."""
    dsi = _v05b.extract_node(base, "dsi@ff450000")
    if not dsi:
        raise SystemExit("dsi@ff450000 missing")

    m = re.search(r"phys = <([^>]+)>;", dsi)
    if not m:
        raise SystemExit("dsi phys missing")
    phy_ref = m.group(1).strip()

    new = dsi
    new = set_or_replace_prop(
        new,
        "clocks",
        f"clocks = <0x02 0x144 {phy_ref}>;",
    )
    new = set_or_replace_prop(new, "clock-names", 'clock-names = "pclk\\0hs_clk";')
    new = set_or_replace_prop(new, "phy-names", 'phy-names = "mipi_dphy";')
    # rockchip,grf : garder panel4 (meme SoC, numerotation DT differente stock)
    return _v05b.replace_node(base, "dsi@ff450000", new)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="", help="default: boot/dtb/v30-panel4.dtb")
    ap.add_argument("--stock", default="", help="stock rk3326-r36s-linux-stock.dtb")
    ap.add_argument("--out", default="", help="default: boot/dtb/y3506-v05d.dtb")
    args = ap.parse_args()

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    base = args.base or os.path.join(root, "boot/dtb/v30-panel4.dtb")
    stock = args.stock or os.path.join(
        root,
        "dtb_backup/Y3506_V05_20251215 2601/rk3326-r36s-linux-stock.dtb",
    )
    out = args.out or os.path.join(root, "boot/dtb/y3506-v05d.dtb")

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

        text = patch_phy_stock_style(text, stock_text)
        text = patch_dsi_stock_style(text)
        text = _v05c.patch_panel_stock_full(text, stock, stock_text)
        text = re.sub(
            r'model = "[^"]+";',
            'model = "Telmi Y3506_V05d (DSI stock + panel stock)";',
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
    print("  phy  : px30-video-phy + #clock-cells (style stock)")
    print("  dsi  : pclk + hs_clk, phy-names = mipi_dphy")
    print("  panel: stock complet (comme v05c)")


if __name__ == "__main__":
    main()
