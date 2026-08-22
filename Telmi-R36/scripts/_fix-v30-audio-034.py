#!/usr/bin/env python3
"""0.3.4: revert codec props that broke ALSA probe on 5.10; keep spk-con + gamepad."""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


def main() -> int:
    dts = Path(sys.argv[1])
    dtb = Path(sys.argv[2]) if len(sys.argv) > 2 else dts.with_suffix(".dtb")
    text = dts.read_text()

    old = (
        "\t\t\t\tspk-mute-delay-ms = <0x32>;\n"
        "\t\t\t\tuse-ext-amplifier;\n"
        "\t\t\t\tspk-ctl-gpios = <0x66 0x07 0x00>;\n"
        "\t\t\t\thp-volume = <0x14>;\n"
        "\t\t\t\tspk-volume = <0x03>;\n"
        "\t\t\t\tvolume-min-db = <0x48>;\n"
    )
    new = (
        "\t\t\t\thp-volume = <0x14>;\n"
        "\t\t\t\tspk-volume = <0x06>;\n"
    )
    if old in text:
        text = text.replace(old, new, 1)
        print("codec: reverted use-ext-amplifier/spk-ctl")
    else:
        text2, n = re.subn(
            r"\n\t\t\t\tspk-mute-delay-ms = <[^>]+>;"
            r"\n\t\t\t\tuse-ext-amplifier;"
            r"\n\t\t\t\tspk-ctl-gpios = <[^>]+>;"
            r"(\n\t\t\t\thp-volume = <[^>]+>;)"
            r"\n\t\t\t\tspk-volume = <[^>]+>;"
            r"(?:\n\t\t\t\tvolume-min-db = <[^>]+>;)?",
            r"\1\n\t\t\t\tspk-volume = <0x06>;",
            text,
            count=1,
        )
        if not n:
            print("ERROR: codec revert failed", file=sys.stderr)
            return 1
        text = text2
        print("codec: fuzzy revert OK")

    if "spk-con-gpio = <0x66 0x07 0x00>;" not in text:
        needle = '\trockchip,card-name = "rockchip-rk817";\n'
        insert = needle + "\t\tspk-con-gpio = <0x66 0x07 0x00>;\n"
        if needle not in text:
            print("ERROR: sound card name missing", file=sys.stderr)
            return 1
        text = text.replace(needle, insert, 1)
        print("sound: added spk-con-gpio")
    else:
        print("sound: spk-con-gpio kept")

    # V20 multicodecs original polarity (card probed with this on 0.3.0/0.3.1)
    text = text.replace(
        "hp-det-gpio = <0x6f 0x16 0x01>;",
        "hp-det-gpio = <0x6f 0x16 0x00>;",
        1,
    )
    print("hp-det: ACTIVE_HIGH")

    dts.write_text(text)
    r = subprocess.run(
        ["dtc", "-f", "-I", "dts", "-O", "dtb", "-o", str(dtb), str(dts)],
        capture_output=True,
        text=True,
    )
    if r.returncode != 0 and not dtb.exists():
        sys.stderr.write(r.stderr)
        return r.returncode or 1
    print(f"OK {dtb} ({dtb.stat().st_size})")
    print("use-ext", "use-ext-amplifier" in text)
    print("spk-ctl", "spk-ctl-gpios" in text)
    print("spk-con", "spk-con-gpio" in text)
    print("gamepad", "telmi-v30-gamepad" in text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
