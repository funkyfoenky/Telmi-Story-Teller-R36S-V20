#!/usr/bin/env bash
# Flash OS Telmi sur slot DROIT sans partition contenu (dual-SD). Linux / macOS.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$DIR/scripts/flash-telmi-sd.sh" --os-only "$@"
