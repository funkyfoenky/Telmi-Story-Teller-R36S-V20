#!/usr/bin/env python3
"""Fix V20→V30 ported DTB: disable clone adc-keys (phantom VOL-), add GPIO vol keys."""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


def node_span(text: str, start: int) -> tuple[int, int]:
    brace = text.find("{", start)
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
                return start, end
        i += 1
    raise SystemExit("unclosed node")


def main() -> int:
    dts_path = Path(sys.argv[1])
    dtb_path = Path(sys.argv[2]) if len(sys.argv) > 2 else dts_path.with_suffix(".dtb")
    text = dts_path.read_text()

    m = re.search(r"\n\tadc-keys \{", text)
    if not m:
        raise SystemExit("adc-keys not found")
    s, e = node_span(text, m.start() + 1)
    node = text[s:e]
    if 'status = "disabled"' not in node:
        node = re.sub(
            r'(compatible = "adc-keys";)',
            r'\1\n\t\tstatus = "disabled";',
            node,
            count=1,
        )
        text = text[:s] + node + text[e:]
        print("disabled adc-keys")
    else:
        print("adc-keys already disabled")

    if "telmi-v30-volume-keys" not in text:
        # P4: VOL on gpio2 pins 0/1. In V20 dts, gpio2@ff260000 phandle = 0x6f
        vol = """
	telmi-v30-volume-keys {
		compatible = "gpio-keys";
		autorepeat;

		button@0 {
			label = "GPIO BTN-VOLUP";
			linux,code = <0x73>;
			gpios = <0x6f 0x00 0x01>;
			debounce-interval = <0x0a>;
		};

		button@1 {
			label = "GPIO BTN-VOLDN";
			linux,code = <0x72>;
			gpios = <0x6f 0x01 0x01>;
			debounce-interval = <0x0a>;
		};
	};
"""
        text = text.replace("\n\tadc-keys {", vol + "\n\tadc-keys {", 1)
        print("added telmi-v30-volume-keys")
    else:
        print("volume keys already present")

    dts_path.write_text(text)
    r = subprocess.run(
        ["dtc", "-f", "-I", "dts", "-O", "dtb", "-o", str(dtb_path), str(dts_path)],
        capture_output=True,
        text=True,
    )
    if r.returncode != 0 and not dtb_path.exists():
        sys.stderr.write(r.stderr)
        return r.returncode or 1
    print(f"OK {dtb_path} ({dtb_path.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
