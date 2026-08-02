#!/usr/bin/env bash
# Nettoie les caches Buildroot / Telmi dans WSL (sans toucher aux sources).
# Usage : bash Telmi-R36/scripts/cleanup-wsl-build-cache.sh
# Option : --deep  supprime aussi dl/ (telechargements, ~6 Go) — rebuild plus long ensuite
set -euo pipefail

BUILDROOT_DIR="${BUILDROOT_DIR:-$HOME/r36s-helloworld-build/buildroot-r36s}"
DEEP=0
[[ "${1:-}" == "--deep" ]] && DEEP=1

echo "==> Avant :"
du -sh "$BUILDROOT_DIR" 2>/dev/null || { echo "Pas de Buildroot dans $BUILDROOT_DIR"; exit 0; }

# Copie locale du paquet qui incluait les .img (bug corrige)
if [[ -d "$BUILDROOT_DIR/output/build/telmi-r36s" ]]; then
	echo "==> Supprime output/build/telmi-r36s (souvent 6 Go, copie des images)..."
	rm -rf "$BUILDROOT_DIR/output/build/telmi-r36s"
fi

# Objets de compilation (rebuildable)
if [[ -d "$BUILDROOT_DIR/output/build" ]]; then
	echo "==> Supprime output/build (objets)..."
	rm -rf "$BUILDROOT_DIR/output/build"
fi

# Images intermediaires Buildroot (pas nos .img Telmi sur C:)
if [[ -d "$BUILDROOT_DIR/output/images" ]]; then
	echo "==> Supprime output/images Buildroot..."
	rm -rf "$BUILDROOT_DIR/output/images"
fi

if [[ "$DEEP" -eq 1 && -d "$BUILDROOT_DIR/dl" ]]; then
	echo "==> --deep : supprime dl/ (sources telechargees)..."
	rm -rf "$BUILDROOT_DIR/dl"
fi

echo "==> Apres :"
du -sh "$BUILDROOT_DIR" 2>/dev/null || true
echo ""
echo "Note : le fichier ext4.vhdx Windows ne retrecit PAS tout seul."
echo "Pour recuperer l'espace sur C: :"
echo "  1. wsl --shutdown"
echo "  2. Optimize-VHD ou diskpart compact (voir README)"
echo "Rebuild Telmi ensuite : bash Telmi-R36/scripts/build-telmi-rootfs.sh"
