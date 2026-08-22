#!/usr/bin/env python3
"""
Port ArkOS Panel 4 display node into V20 5.10 DTB (rf3536k3ka).

Why Panel 4 (not 5):
  Panel 5 PID = "Soy Sauce Console" — autre hardware.
  Panel 4 = elida,kd35t133 — celui qui boote sur la V30 utilisateur.

Strategy:
  - Keep V20 SoC / pinctrl / graph endpoints / backlight phandle
  - Swap compatible + init/exit sequences + timings + delays from Panel 4
  - reset: same gpio3@ff270000, pin 16 (Panel 4) instead of pin 15 (V20)
  - power-supply: prefer V20 LDO_REG8 (Panel 4) over vcc18-lcd-n
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path


def extract_node(text: str, name: str) -> tuple[int, int, str] | None:
    m = re.search(rf"{re.escape(name)}\s*\{{", text)
    if not m:
        return None
    start = m.start()
    brace = text.find("{", m.start())
    depth = 0
    i = brace
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                if end < len(text) and text[end] == ";":
                    end += 1
                return start, end, text[start:end]
        i += 1
    return None


def prop(block: str, key: str) -> str | None:
    m = re.search(rf"{re.escape(key)}\s*=\s*([^;]+);", block, re.S)
    return m.group(1).strip() if m else None


def timing60_from_p4(p4_panel: str) -> str:
    m = re.search(r"60Hz\s*\{([\s\S]*?)\n\t\t\t\t\}", p4_panel)
    if not m:
        raise SystemExit("Panel4 60Hz timing not found")
    body = m.group(1)
    # drop phandle line from donor
    lines = []
    for line in body.splitlines():
        if "phandle" in line:
            continue
        if line.strip():
            lines.append(line)
    return "\n".join(lines)


def build_panel(v20_panel: str, p4_panel: str, gpio3_ph: str, ldo_ph: str, bl_ph: str) -> str:
    init = prop(p4_panel, "panel-init-sequence")
    exit_seq = prop(p4_panel, "panel-exit-sequence")
    if not init or not exit_seq:
        raise SystemExit("missing init/exit in panel4")

    timing_body = timing60_from_p4(p4_panel)

    # Keep ports{} subtree from V20 (graph endpoints / phandles)
    ports = extract_node(v20_panel, "ports")
    ports_txt = ports[2] if ports else ""

    # native-mode phandle: reuse V20 timing0 phandle if present
    nm = prop(v20_panel, "native-mode") or "<0xa0>"
    timing_ph = nm.strip("<> ")

    return f"""panel@0 {{
			compatible = "elida,kd35t133\\0simple-panel-dsi";
			reg = <0x00>;
			backlight = <{bl_ph}>;
			power-supply = <{ldo_ph}>;
			prepare-delay-ms = <0x14>;
			reset-delay-ms = <0x96>;
			init-delay-ms = <0x14>;
			enable-delay-ms = <0x78>;
			disable-delay-ms = <0x32>;
			unprepare-delay-ms = <0x14>;
			width-mm = <0x34>;
			height-mm = <0x46>;
			dsi,flags = <0xa03>;
			dsi,format = <0x00>;
			dsi,lanes = <0x04>;
			panel-init-sequence = {init};
			panel-exit-sequence = {exit_seq};
			reset-gpios = <{gpio3_ph} 0x10 0x01>;

			display-timings {{
				native-mode = <{timing_ph}>;

				timing0 {{
{timing_body}
					phandle = <{timing_ph}>;
				}};
			}};

			{ports_txt}
		}};"""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--v20-dts", type=Path, required=True)
    ap.add_argument("--p4-panel", type=Path, required=True)
    ap.add_argument("--out-dts", type=Path, required=True)
    ap.add_argument("--out-dtb", type=Path, required=True)
    args = ap.parse_args()

    v20 = args.v20_dts.read_text(errors="replace")
    p4_panel = args.p4_panel.read_text(errors="replace")

    v20_panel = extract_node(v20, "panel@0")
    if not v20_panel:
        raise SystemExit("panel@0 not found in V20 dts")

    # Resolve phandles from original V20 panel
    bl = prop(v20_panel[2], "backlight") or "<0x9e>"
    bl_ph = bl.strip("<> ").split()[0]
    # gpio3 from original reset ctl
    rg = re.search(
        r"reset-gpios\s*=\s*<(0x[0-9a-fA-F]+)\s+0x[0-9a-fA-F]+\s+0x[0-9a-fA-F]+>",
        v20_panel[2],
    )
    gpio3_ph = rg.group(1) if rg else "0x66"
    ldo_ph = "0x6e"  # LDO_REG8 in working-v20 dts

    new_panel = build_panel(v20_panel[2], p4_panel, gpio3_ph, ldo_ph, bl_ph)
    out = v20[: v20_panel[0]] + new_panel + v20[v20_panel[1] :]
    args.out_dts.write_text(out)

    # dtc may warn; accept warnings
    r = subprocess.run(
        ["dtc", "-I", "dts", "-O", "dtb", "-o", str(args.out_dtb), str(args.out_dts)],
        capture_output=True,
        text=True,
    )
    sys.stderr.write(r.stderr)
    if r.returncode != 0 and not args.out_dtb.exists():
        print(r.stdout)
        return r.returncode or 1
    # retry with -f if needed
    if not args.out_dtb.exists() or args.out_dtb.stat().st_size < 1000:
        r = subprocess.run(
            [
                "dtc",
                "-f",
                "-I",
                "dts",
                "-O",
                "dtb",
                "-o",
                str(args.out_dtb),
                str(args.out_dts),
            ],
            capture_output=True,
            text=True,
        )
        sys.stderr.write(r.stderr)
        if r.returncode != 0:
            return r.returncode

    print(f"OK {args.out_dtb} ({args.out_dtb.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
