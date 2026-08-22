#!/usr/bin/env python3
"""
Port joypad GPIOs Panel4 (ArkOS odroidgo3-joypad) into V20 5.10 DTB.

Le DTB clone V20 (play_joystick) écoute gpio3/gpio2 — sur V30 Panel4
les face buttons + D-pad sont sur gpio1. Résultat : FN/Power OK, D-pad/A/B morts.

Stratégie :
  - gpio-key-num=0 sur play_joystick (garde les sticks ADC, libère les GPIO boutons)
  - nœud telmi-v30-gamepad (gpio-keys) avec pins P4 + codes keymap Telmi
  - pinctrl buttons élargi (gpio1 inclus)
  - volume keys sans autorepeat (évite le flood si pin flottante)
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

# V20 dts phandles:
#   gpio1@ff250000 = 0xc9
#   gpio2@ff260000 = 0x6f
#   gpio3@ff270000 = 0x66
#   pcfg-pull-up   = 0xb9
GPIO1, GPIO2, GPIO3 = 0xC9, 0x6F, 0x66
PULL = 0xB9

# linux,code (input-event-codes) — alignés sur keymap_hw.h Telmi
BTN_SOUTH, BTN_EAST, BTN_NORTH, BTN_WEST = 0x130, 0x131, 0x133, 0x134
BTN_TL, BTN_TR, BTN_TL2, BTN_TR2 = 0x136, 0x137, 0x138, 0x139
BTN_SELECT, BTN_START = 0x13A, 0x13B
BTN_DPAD_UP, BTN_DPAD_DOWN = 0x220, 0x221
BTN_DPAD_LEFT, BTN_DPAD_RIGHT = 0x222, 0x223
BTN_FN = 0x2C4  # BTN_TRIGGER_HAPPY5

# Pins = mapping ArkOS Panel4 (odroidgo3-joypad), codes = Telmi V20
BUTTONS = [
    # label, code, gpio_phandle, pin
    ("DPAD-UP", BTN_DPAD_UP, GPIO1, 0x0C),
    ("DPAD-DOWN", BTN_DPAD_DOWN, GPIO1, 0x0D),
    ("DPAD-LEFT", BTN_DPAD_LEFT, GPIO1, 0x0E),
    ("DPAD-RIGHT", BTN_DPAD_RIGHT, GPIO1, 0x0F),
    ("BTN-A", BTN_SOUTH, GPIO1, 0x02),
    ("BTN-B", BTN_EAST, GPIO1, 0x05),
    ("BTN-Y", BTN_WEST, GPIO1, 0x06),
    ("BTN-X", BTN_NORTH, GPIO1, 0x07),
    ("BTN-L1", BTN_TL, GPIO2, 0x06),
    ("BTN-R1", BTN_TR, GPIO2, 0x07),
    ("BTN-L2", BTN_TL2, GPIO3, 0x0A),
    ("BTN-R2", BTN_TR2, GPIO3, 0x0F),
    ("BTN-SELECT", BTN_SELECT, GPIO3, 0x09),
    ("BTN-START", BTN_START, GPIO3, 0x0C),
    ("BTN-FN", BTN_FN, GPIO2, 0x04),
]


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


def gamepad_node() -> str:
    lines = [
        "\n\ttelmi-v30-gamepad {",
        '\t\tcompatible = "gpio-keys";',
        "\t\t#address-cells = <0x01>;",
        "\t\t#size-cells = <0x00>;",
        "\t\tautorepeat;",
        "",
    ]
    for i, (label, code, bank, pin) in enumerate(BUTTONS):
        lines += [
            f"\t\tbutton@{i} {{",
            f'\t\t\tlabel = "GPIO {label}";',
            f"\t\t\tlinux,code = <0x{code:x}>;",
            f"\t\t\tgpios = <0x{bank:x} 0x{pin:x} 0x01>;",
            "\t\t\tdebounce-interval = <0x0a>;",
            "\t\t};",
            "",
        ]
    lines.append("\t};")
    return "\n".join(lines) + "\n"


def patch_play_joystick(text: str) -> str:
    m = re.search(r"\n\tplay_joystick \{", text)
    if not m:
        raise SystemExit("play_joystick not found")
    s, e = node_span(text, m.start() + 1)
    node = text[s:e]
    node2, n = re.subn(
        r"gpio-key-num = <0x[0-9a-fA-F]+>;",
        "gpio-key-num = <0x00>;",
        node,
        count=1,
    )
    if n == 0:
        raise SystemExit("gpio-key-num not found in play_joystick")
    # Garder la propriété (probe driver) mais 1 pin inutilisé pour éviter
    # le conflit avec telmi-v30-gamepad / audio.
    node2, n2 = re.subn(
        r"key-gpios = <[^>]+>;",
        "key-gpios = <0x66 0x1b 0x01>;",
        node2,
        count=1,
    )
    if n2:
        print("play_joystick: key-gpios -> dummy gpio3.27")
    print("play_joystick: gpio-key-num=0 (digital keys off)")
    return text[:s] + node2 + text[e:]


def patch_v30_audio(text: str) -> str:
    """Audio V30 safe for noyau 5.10 : spk-con seul.

    NOTE: use-ext-amplifier + spk-ctl-gpios sur le codec CASSE le probe
    ALSA (card0 absent) sur ce kernel — ne pas les remettre.
    """
    # Strip broken ArkOS codec props if present
    text2, n = re.subn(
        r"\n\t\t\t\tspk-mute-delay-ms = <[^>]+>;"
        r"\n\t\t\t\tuse-ext-amplifier;"
        r"\n\t\t\t\tspk-ctl-gpios = <[^>]+>;",
        "",
        text,
        count=1,
    )
    if n:
        text = text2
        print("codec: removed use-ext-amplifier/spk-ctl (breaks 5.10 probe)")

    text2, n = re.subn(r"\n\t\t\t\tvolume-min-db = <[^>]+>;", "", text, count=1)
    if n:
        text = text2

    if "spk-con-gpio" not in text:
        text = text.replace(
            '\trockchip,card-name = "rockchip-rk817";\n',
            '\trockchip,card-name = "rockchip-rk817";\n'
            "\t\tspk-con-gpio = <0x66 0x07 0x00>;\n",
            1,
        )
        print("sound: added spk-con-gpio gpio3.7")
    return text


def patch_pinctrl_buttons(text: str) -> str:
    """Ajoute les pins gpio1/2/3 Panel4 au groupe gpio-key-pin."""
    m = re.search(
        r"(gpio-key-pin \{[^}]*?rockchip,pins = <)([^>]+)(>;)",
        text,
        re.S,
    )
    if not m:
        print("WARN: gpio-key-pin pinctrl not found")
        return text
    pins = m.group(2)
    extra = [
        f"0x01 0x{p:02x} 0x00 0x{PULL:x}"
        for p in (0x02, 0x05, 0x06, 0x07, 0x0C, 0x0D, 0x0E, 0x0F)
    ]
    extra += [
        f"0x02 0x{p:02x} 0x00 0x{PULL:x}"
        for p in (0x00, 0x01, 0x02, 0x03, 0x04, 0x06, 0x07)
    ]
    extra += [
        f"0x03 0x{p:02x} 0x00 0x{PULL:x}"
        for p in (0x09, 0x0A, 0x0C, 0x0F)
    ]
    merged = pins.strip()
    added = 0
    for e in extra:
        if e not in merged:
            merged += " " + e
            added += 1
    print(f"pinctrl gpio-key-pin: +{added} Panel4 entries")
    return text[: m.start()] + m.group(1) + merged + m.group(3) + text[m.end() :]


def patch_volume_autorepeat(text: str) -> str:
    m = re.search(r"\n\ttelmi-v30-volume-keys \{", text)
    if not m:
        return text
    s, e = node_span(text, m.start() + 1)
    node = text[s:e]
    if "autorepeat;" in node:
        node = node.replace("\n\t\tautorepeat;", "", 1)
        print("telmi-v30-volume-keys: removed autorepeat")
        return text[:s] + node + text[e:]
    return text


def main() -> int:
    dts_path = Path(sys.argv[1])
    dtb_path = Path(sys.argv[2]) if len(sys.argv) > 2 else dts_path.with_suffix(".dtb")
    text = dts_path.read_text()

    text = patch_play_joystick(text)
    text = patch_pinctrl_buttons(text)
    text = patch_volume_autorepeat(text)
    text = patch_v30_audio(text)

    if "telmi-v30-gamepad" not in text:
        # Insert before play_joystick
        text = text.replace("\n\tplay_joystick {", gamepad_node() + "\n\tplay_joystick {", 1)
        print(f"added telmi-v30-gamepad ({len(BUTTONS)} buttons)")
    else:
        print("telmi-v30-gamepad already present")

    dts_path.write_text(text)
    r = subprocess.run(
        ["dtc", "-f", "-I", "dts", "-O", "dtb", "-o", str(dtb_path), str(dts_path)],
        capture_output=True,
        text=True,
    )
    if r.returncode != 0 and not dtb_path.exists():
        sys.stderr.write(r.stderr)
        return r.returncode or 1
    if r.stderr:
        # dtc -f may warn; show brief
        warns = [ln for ln in r.stderr.splitlines() if "Warning" in ln or "Error" in ln]
        for ln in warns[:12]:
            print(ln)
    print(f"OK {dtb_path} ({dtb_path.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
