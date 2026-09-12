#!/usr/bin/env bash
# Prépare la SD CONTENU (slot gauche) — FAT32 label TELMI. Linux / macOS.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$DIR/scripts/prepare-content-sd.sh" "$@"
