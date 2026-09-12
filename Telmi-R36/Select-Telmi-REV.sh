#!/usr/bin/env bash
# Sélection REV (V20 / V30 / Y3506) sur le volume BOOT. Linux / macOS.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$DIR/scripts/select-telmi-rev.sh" "$@"
