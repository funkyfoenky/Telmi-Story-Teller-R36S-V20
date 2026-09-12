#!/usr/bin/env bash
# Flash TelmiOS + expand TELMI (single-SD). Linux / macOS.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$DIR/scripts/flash-telmi-sd.sh" --from-image "$@"
