#!/usr/bin/env bash
# Telecharge les assets UI Telmi (polices, PNG, configs) depuis la release GitHub.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TELMI_R36="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE="$TELMI_R36/cache"
ASSETS="$TELMI_R36/assets"
URL="https://github.com/DantSu/Telmi-story-teller/releases/download/1.10.1/TelmiOS_v1.10.1.zip"
ZIP="$CACHE/TelmiOS_v1.10.1.zip"

mkdir -p "$CACHE" "$ASSETS"
if [[ ! -f "$ZIP" ]]; then
	echo "==> Telechargement TelmiOS_v1.10.1.zip..."
	wget -q -O "$ZIP" "$URL"
fi

echo "==> Extraction assets..."
rm -rf "$CACHE/extract"
mkdir -p "$CACHE/extract"
unzip -q -o "$ZIP" -d "$CACHE/extract"

rm -rf "$ASSETS"/*
mkdir -p "$ASSETS/res" "$ASSETS/config"
rsync -a "$CACHE/extract/.tmp_update/res/" "$ASSETS/res/" 2>/dev/null || true
rsync -a "$CACHE/extract/.tmp_update/config/" "$ASSETS/config/" 2>/dev/null || true
rsync -a "$TELMI_R36/Telmi-story-teller-1.10.1/static/configs/" "$ASSETS/" 2>/dev/null || true

echo "Assets dans $ASSETS"
ls -la "$ASSETS/res" 2>/dev/null | head -15
