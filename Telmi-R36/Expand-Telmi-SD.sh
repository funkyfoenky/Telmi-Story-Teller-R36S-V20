#!/usr/bin/env bash
# Recrée seulement la partition TELMI (après Balena / flash partiel). Linux / macOS.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$DIR/scripts/flash-telmi-sd.sh" --expand "$@"
