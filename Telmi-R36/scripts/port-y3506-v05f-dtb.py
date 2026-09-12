#!/usr/bin/env python3
"""Y3506 V05f — v05e + alim panel stock (RK817 vcc_lcd) + graphe DSI stock.

Lecon v05e (reset) :
  - fb0/DRM/SDL OK (route VOP)
  - dw-mipi-dsi: failed to find panel or bridge: -517 (EPROBE_DEFER)
  - backlight + LED bleue, pas d'image LCD

Cause probable :
  - panel power-supply = vcc18-lcd-n (Panel4) au lieu de LDO_REG8 vcc_lcd (stock Y3506)
  - ports graph panel4 (dsi port@1 + panel ports) absents du stock

v05f :
  - tout v05e (panel4 DSI, route VOP, panel stock)
  - LDO_REG8 renomme vcc_lcd + panel power-supply -> LDO_REG8
  - vcc18-lcd-n disabled
  - supprime dsi/ports/port@1 et panel@0/ports (style stock)
  - backlight default-brightness stock (0x50)

Usage :
  python3 scripts/port-y3506-v05f-dtb.py
"""
from __future__ import annotations

import argparse
import importlib.util
import os
import re
import subprocess
import tempfile

_SCRIPT_V05E = os.path.join(os.path.dirname(__file__), "port-y3506-v05e-dtb.py")
_spec = importlib.util.spec_from_file_location("v05e", _SCRIPT_V05E)
_v05e = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_v05e)
_v05b = _v05e._v05b


def phandle_of(block: str) -> str:
    m = re.search(r"phandle\s*=\s*<([^>]+)>", block)
    if not m:
        raise SystemExit(f"phandle missing in:\n{block[:120]}...")
    return m.group(1).strip()


def patch_ldo_reg8_vcc_lcd(text: str) -> tuple[str, str]:
    """RK817 LDO_REG8 : vcc1v8_dvp -> vcc_lcd (comme stock Y3506)."""
    m = re.search(
        r"(\t\t\t\tLDO_REG8 \{[^}]+\})",
        text,
        re.S,
    )
    if not m:
        raise SystemExit("LDO_REG8 missing")
    old = m.group(1)
    new = re.sub(
        r'regulator-name = "vcc1v8_dvp";',
        'regulator-name = "vcc_lcd";',
        old,
        count=1,
    )
    if new == old:
        raise SystemExit("LDO_REG8 regulator-name not updated")
    ph = phandle_of(new)
    return text.replace(old, new, 1), ph


def patch_panel_power_supply(text: str, ldo_ph: str) -> str:
    panel = _v05b.extract_node(text, "panel@0")
    if not panel:
        raise SystemExit("panel@0 missing")
    new = re.sub(
        r"power-supply\s*=\s*<[^>]+>;",
        f"power-supply = <{ldo_ph}>;",
        panel,
        count=1,
    )
    if new == panel:
        raise SystemExit("panel power-supply missing")
    return _v05b.replace_node(text, "panel@0", new)


def disable_vcc18_lcd_n(text: str) -> str:
    node = _v05b.extract_node(text, "vcc18-lcd-n")
    if not node:
        return text
    if re.search(r"^\s*status\s*=", node, re.M):
        new = re.sub(r'^\s*status\s*=\s*"[^"]+";', '\tstatus = "disabled";', node, count=1, flags=re.M)
    else:
        new = re.sub(
            r"(vcc18-lcd-n \{)\n",
            r'\1\n\t\tstatus = "disabled";\n',
            node,
            count=1,
        )
    return text.replace(node, new, 1)


def remove_panel_ports(text: str) -> str:
    panel = _v05b.extract_node(text, "panel@0")
    if not panel:
        raise SystemExit("panel@0 missing")
    ports = _v05b.extract_node(panel, "ports")
    if not ports:
        return text
    new_panel = panel.replace(ports, "", 1)
    new_panel = re.sub(r"\n\n+", "\n", new_panel)
    return _v05b.replace_node(text, "panel@0", new_panel)


def remove_dsi_port1(text: str) -> str:
    dsi = _v05b.extract_node(text, "dsi@ff450000")
    if not dsi:
        raise SystemExit("dsi@ff450000 missing")
    ports = _v05b.extract_node(dsi, "ports")
    if not ports:
        return text
    port1 = _v05b.extract_node(ports, "port@1")
    if not port1:
        return text
    new_ports = ports.replace(port1, "", 1)
    new_ports = re.sub(r"\n\n+", "\n", new_ports)
    new_dsi = dsi.replace(ports, new_ports, 1)
    return _v05b.replace_node(text, "dsi@ff450000", new_dsi)


def patch_backlight_defaults(text: str, stock_dts: str) -> str:
    bl = _v05b.extract_node(text, "backlight")
    stock_bl = _v05b.extract_node(stock_dts, "backlight")
    if not bl or not stock_bl:
        return text
    new = bl
    m = re.search(r"default-brightness-level\s*=\s*<([^>]+)>", stock_bl)
    if m:
        new = re.sub(
            r"default-brightness-level\s*=\s*<[^>]+>;",
            f"default-brightness-level = <{m.group(1).strip()}>;",
            new,
            count=1,
        )
    return text.replace(bl, new, 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="", help="default: boot/dtb/v30-panel4.dtb")
    ap.add_argument("--stock", default="", help="stock rk3326-r36s-linux-stock.dtb")
    ap.add_argument("--out", default="", help="default: boot/dtb/y3506-v05f.dtb")
    args = ap.parse_args()

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    base = args.base or os.path.join(root, "boot/dtb/v30-panel4.dtb")
    stock = args.stock or os.path.join(
        root,
        "dtb_backup/Y3506_V05_20251215 2601/rk3326-r36s-linux-stock.dtb",
    )
    out = args.out or os.path.join(root, "boot/dtb/y3506-v05f.dtb")

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

        text = _v05e._v05c.patch_panel_stock_full(text, stock, stock_text)
        text = _v05e.patch_vop_dsi_route_y3506(text)
        text = _v05e.patch_backlight_pwm_period(text, stock_text)
        text, ldo_ph = patch_ldo_reg8_vcc_lcd(text)
        text = patch_panel_power_supply(text, ldo_ph)
        text = disable_vcc18_lcd_n(text)
        text = remove_panel_ports(text)
        text = remove_dsi_port1(text)
        text = patch_backlight_defaults(text, stock_text)
        text = re.sub(
            r'model = "[^"]+";',
            'model = "Telmi Y3506_V05f (v05e + vcc_lcd RK817)";',
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
    print(f"  panel power-supply : LDO_REG8 vcc_lcd (phandle {ldo_ph})")
    print("  vcc18-lcd-n        : disabled")
    print("  dsi/panel ports    : stock (sans port@1 / sans panel ports)")
    print("  base               : v05e (panel4 DSI + route VOP stock)")


if __name__ == "__main__":
    main()
