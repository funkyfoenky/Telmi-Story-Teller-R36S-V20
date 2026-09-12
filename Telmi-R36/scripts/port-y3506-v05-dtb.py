#!/usr/bin/env python3
"""Port DarkOS Y3506_V05 panel + SD wiring onto Telmi 5.10 v20.dtb.

Do NOT flash the DarkOS DTB as-is: Telmi kernel is 5.10 (clone V20),
DarkOS DTB is a different kernel ABI (odroidgo3-joypad, different DSI PHY).

Same strategy as v30-panel4: keep v20 5.10 skeleton, swap panel init/timings
and left-SD card-detect.
"""
from __future__ import annotations

import argparse
import os
import re
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
    """Replace or insert a single-line property in a node block (first level-ish)."""
    pat = re.compile(rf"^(\s*){re.escape(prop)}\s*=\s*.*;\s*$", re.M)
    m = pat.search(block)
    if m:
        return pat.sub(lambda mm: mm.group(1) + value_line, block, count=1)
    # insert after compatible / first inner line
    lines = block.splitlines()
    insert_at = 1
    for i, line in enumerate(lines[1:], 1):
        if line.strip().endswith("{") or line.strip() == "};":
            insert_at = i
            break
        insert_at = i
        if line.strip().startswith("compatible"):
            insert_at = i + 1
            break
    indent = re.match(r"^(\s*)", lines[1] if len(lines) > 1 else "\t\t").group(1)
    lines.insert(insert_at, indent + value_line)
    return "\n".join(lines)


def cells_to_bytes(cells_text: str) -> bytes:
    cells = [int(x, 16) if x.startswith("0x") else int(x) for x in re.findall(r"0x[0-9a-fA-F]+|\d+", cells_text)]
    return b"".join(c.to_bytes(4, "big") for c in cells)


def byte_array_to_dts(raw: bytes) -> str:
    return "[" + " ".join(f"{b:02x}" for b in raw) + "]"


def patch_panel(v20: str, y3506: str) -> str:
    src = extract_node(y3506, "panel@0")
    dst = extract_node(v20, "panel@0")
    if not src or not dst:
        raise SystemExit("panel@0 missing")

    init_m = re.search(r"panel-init-sequence\s*=\s*<([^>]+)>", src)
    if not init_m:
        init_m = re.search(r"panel-init-sequence\s*=\s*(\[[^\]]+\])", src)
        if not init_m:
            raise SystemExit("Y3506 panel-init-sequence not found")
        init_dts = init_m.group(1)
    else:
        init_dts = byte_array_to_dts(cells_to_bytes(init_m.group(1)))

    # Y3506 60Hz timings (native-mode)
    timing_src = extract_node(src, "60Hz")
    if not timing_src:
        raise SystemExit("Y3506 60Hz timings missing")

    def tprop(name, default=None):
        m = re.search(rf"{re.escape(name)}\s*=\s*<([^>]+)>", timing_src)
        if not m:
            if default is not None:
                return default
            raise SystemExit(f"timing prop {name} missing")
        return m.group(1).strip()

    new = dst
    new = re.sub(
        r'compatible = "[^"]+";',
        'compatible = "elida,kd35t133\\0simple-panel-dsi";',
        new,
        count=1,
    )
    replacements = {
        "prepare-delay-ms": "<0x64>",
        "reset-delay-ms": "<0x32>",
        "init-delay-ms": "<0x14>",
        "enable-delay-ms": "<0xc8>",
        "disable-delay-ms": "<0x32>",
        "unprepare-delay-ms": "<0x14>",
        "width-mm": "<0x47>",
        "height-mm": "<0x47>",
        "reset-gpios": "<0x66 0x10 0x01>",  # gpio3.16 (v20 phandle)
        "panel-exit-sequence": "<0x5140128 0x50a0110>",
    }
    for prop, val in replacements.items():
        new = set_prop_line(new, prop, f"{prop} = {val};")

    # enable-gpios gpio1.18 — v20 gpio1 phandle 0xc9
    if "enable-gpios" not in new:
        new = set_prop_line(new, "enable-gpios", "enable-gpios = <0xc9 0x12 0x01>;")
    else:
        new = set_prop_line(new, "enable-gpios", "enable-gpios = <0xc9 0x12 0x01>;")

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

    # Replace timing0 numeric props from Y3506 60Hz; keep phandle 0xa0
    timing0 = extract_node(new, "timing0")
    if not timing0:
        raise SystemExit("v20 timing0 missing")
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
        "pixelclk-active": tprop("pixelclk-active", "<0x00>"),
    }
    for prop, val in tmap.items():
        tnew = set_prop_line(tnew, prop, f"{prop} = <{val}>;" if not val.startswith("<") else f"{prop} = {val};")
    new = new.replace(timing0, tnew, 1)

    # Keep power-supply = vcc18_lcd_n (0x9f) — do not point at LDO8 (vcc1v8_dvp on 5.10)
    return replace_node(v20, "panel@0", new)


def patch_sd(v20: str) -> str:
    left = extract_node(v20, "dwmmc@ff380000")
    if not left:
        raise SystemExit("dwmmc@ff380000 missing")
    new = left
    new = set_prop_line(new, "cd-gpios", "cd-gpios = <0x5c 0x0a 0x01>;")  # gpio0.10
    # 3.3V fixe (lecon V30 0.6.6) : ne pas partager vccio_sd UHS
    new = set_prop_line(new, "vqmmc-supply", "vqmmc-supply = <0x92>;")  # vcc_sd
    new = set_prop_line(new, "vmmc-supply", "vmmc-supply = <0x92>;")
    for uhs in ("sd-uhs-sdr12", "sd-uhs-sdr25", "sd-uhs-sdr50", "sd-uhs-sdr104"):
        new = re.sub(rf"^\s*{uhs};\s*$", "", new, flags=re.M)
    if "no-1-8-v" not in new:
        new = new.replace("status = \"okay\";", "status = \"okay\";\n\t\tno-1-8-v;", 1)
    v20 = replace_node(v20, "dwmmc@ff380000", new)

    emmc = extract_node(v20, "dwmmc@ff390000")
    if emmc and 'status = "okay"' in emmc:
        emmc2 = emmc.replace('status = "okay";', 'status = "disabled";', 1)
        v20 = replace_node(v20, "dwmmc@ff390000", emmc2)
    return v20


def patch_volume(v20: str) -> str:
    adc = extract_node(v20, "adc-keys")
    if adc and "status =" not in adc:
        adc2 = adc.replace(
            'compatible = "adc-keys";',
            'compatible = "adc-keys";\n\t\tstatus = "disabled";',
            1,
        )
        v20 = replace_node(v20, "adc-keys", adc2)

    if "telmi-y3506-volume-keys" in v20:
        return v20
    keys = """	telmi-y3506-volume-keys {
		compatible = "gpio-keys";

		button@0 {
			label = "GPIO BTN-VOLUP";
			linux,code = <0x73>;
			gpios = <0x66 0x16 0x01>;
			debounce-interval = <0x0a>;
		};

		button@1 {
			label = "GPIO BTN-VOLDN";
			linux,code = <0x72>;
			gpios = <0x66 0x15 0x01>;
			debounce-interval = <0x0a>;
		};
	};

"""
    return v20.replace("	adc-keys {", keys + "	adc-keys {", 1)


def patch_model(v20: str) -> str:
    v20 = re.sub(
        r'model = "[^"]+";',
        'model = "Telmi Y3506_V05 (panel+SD port 5.10)";',
        v20,
        count=1,
    )
    return v20


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--v20", required=True, help="Telmi boot/dtb/v20.dtb")
    ap.add_argument("--y3506", required=True, help="DarkOS rk3326-r36s-linux.dtb")
    ap.add_argument("--out", required=True, help="Output y3506-v05.dtb")
    ap.add_argument("--keep-dts", default="", help="Optional path to save patched DTS")
    args = ap.parse_args()

    with tempfile.TemporaryDirectory() as td:
        v20_dts = os.path.join(td, "v20.dts")
        y_dts = os.path.join(td, "y3506.dts")
        run_dtc(["-I", "dtb", "-O", "dts", "-o", v20_dts, args.v20], stderr=subprocess.DEVNULL)
        run_dtc(["-I", "dtb", "-O", "dts", "-o", y_dts, args.y3506], stderr=subprocess.DEVNULL)
        v20 = open(v20_dts, encoding="utf-8", errors="replace").read()
        y3506 = open(y_dts, encoding="utf-8", errors="replace").read()

        v20 = patch_panel(v20, y3506)
        v20 = patch_sd(v20)
        v20 = patch_volume(v20)
        v20 = patch_model(v20)

        patched = os.path.join(td, "patched.dts")
        open(patched, "w", encoding="utf-8", newline="\n").write(v20)
        if args.keep_dts:
            os.makedirs(os.path.dirname(args.keep_dts) or ".", exist_ok=True)
            open(args.keep_dts, "w", encoding="utf-8", newline="\n").write(v20)

        os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
        run_dtc(["-I", "dts", "-O", "dtb", "-o", args.out, patched])
        size = os.path.getsize(args.out)
        print(f"OK {args.out} ({size} bytes)")


if __name__ == "__main__":
    main()
