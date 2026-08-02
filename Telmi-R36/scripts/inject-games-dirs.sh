#!/usr/bin/env bash
# Injecte Games/{gb,gbc,gba,nes,md,snes,psx} dans la partition TELMI (p3) d'une image.
# Ecrit via mtools @@offset (pas d'extraction 100 Mo → evite les hangs /mnt/c).
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export MTOOLS_SKIP_CHECK=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TELMI_R36="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTENT_DIR="$TELMI_R36/content"
IMG="${1:-}"

if [[ -z "$IMG" ]]; then
	if [[ -f "$TELMI_R36/output/LATEST.txt" ]]; then
		IMG="$TELMI_R36/output/$(tr -d '[:space:]' < "$TELMI_R36/output/LATEST.txt")"
	fi
fi
[[ -f "$IMG" ]] || { echo "ERREUR : image introuvable"; exit 1; }

ROOT_PART_START=1056768
ROOT_PART_SIZE_MB=1536
ROOT_PART_SECTORS=$((ROOT_PART_SIZE_MB * 1024 * 1024 / 512))
TELMI_PART_START=$((ROOT_PART_START + ROOT_PART_SECTORS))
TELMI_END=$(parted -s "$IMG" unit s print 2>/dev/null | awk '/^ 3 /{gsub(/s/,"",$3); print $3}')
[[ -n "${TELMI_END:-}" ]] || { echo "ERREUR : pas de partition 3"; exit 1; }
TELMI_PART_SECTORS=$((TELMI_END - TELMI_PART_START + 1))
[[ $TELMI_PART_SECTORS -gt 1000 ]] || { echo "ERREUR : TELMI invalide"; exit 1; }

OFFSET=$((TELMI_PART_START * 512))
MIMG="${IMG}@@${OFFSET}"
KEEP="$(mktemp /tmp/telmi-keep-XXXXXX)"
trap 'rm -f "$KEEP"' EXIT
touch "$KEEP"

echo "==> Image : $IMG"
echo "    TELMI  : start=$TELMI_PART_START sectors=$TELMI_PART_SECTORS offset=$OFFSET"

# mtools sur FAT32 in-place (pas de dd extract)
mmd -i "$MIMG" ::/Games 2>/dev/null || true
mmd -i "$MIMG" ::/Saves 2>/dev/null || true
for d in gb gbc gba nes md snes psx; do
	mmd -i "$MIMG" "::/Games/$d" 2>/dev/null || true
	mcopy -o -i "$MIMG" "$KEEP" "::/Games/$d/.keep" 2>/dev/null || true
done

[[ -f "$CONTENT_DIR/Games/README.txt" ]] && \
	mcopy -o -i "$MIMG" "$CONTENT_DIR/Games/README.txt" ::/Games/README.txt || true
[[ -f "$CONTENT_DIR/Saves/README-BIOS-PSX.txt" ]] && \
	mcopy -o -i "$MIMG" "$CONTENT_DIR/Saves/README-BIOS-PSX.txt" ::/Saves/README-BIOS-PSX.txt || true

echo "==> Games/ :"
mdir -i "$MIMG" ::/Games || true
sync
echo "OK — dossiers Games presents sur TELMI"
