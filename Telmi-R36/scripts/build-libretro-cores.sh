#!/bin/bash
# Cross-compile les cores libretro pour TelmiOS (aarch64)
# Usage: CORE_CACHE=/path HOST_DIR=/path/to/buildroot/output/host bash build-libretro-cores.sh
set -euo pipefail

CORE_CACHE="${CORE_CACHE:-/home/funkyfoenky/telmi-emu-cores}"
HOST_DIR="${HOST_DIR:-/home/funkyfoenky/r36s-helloworld-build/buildroot-r36s/output/host}"
OUT_DIR="${OUT_DIR:-}"
CC="${HOST_DIR}/bin/aarch64-linux-gcc"
CXX="${HOST_DIR}/bin/aarch64-linux-g++"
STRIP="${HOST_DIR}/bin/aarch64-linux-strip"
PERSIST_OUT="${PERSIST_OUT:-/home/funkyfoenky/telmi-cores-out}"

CORES_WANTED=(
	gambatte_libretro.so
	fceumm_libretro.so
	snes9x2005_libretro.so
	picodrive_libretro.so
	mgba_libretro.so
	pcsx_rearmed_libretro.so
)

if [ ! -x "$CC" ]; then
	echo "Toolchain introuvable: $CC" >&2
	exit 1
fi
if [ -z "$OUT_DIR" ]; then
	echo "OUT_DIR requis (ex: staging/opt/telmi/lib/cores)" >&2
	exit 1
fi

mkdir -p "$OUT_DIR" "$CORE_CACHE" "$PERSIST_OUT"
export PATH="${HOST_DIR}/bin:$PATH"

# Copie depuis le cache persistant si tous les cores sont deja la
NEED=0
for so in "${CORES_WANTED[@]}"; do
	if [ ! -f "$PERSIST_OUT/$so" ]; then
		NEED=1
		break
	fi
done
if [ "$NEED" -eq 0 ]; then
	echo "==> Cores deja presents dans $PERSIST_OUT — copie vers $OUT_DIR"
	mkdir -p "$OUT_DIR"
	rm -f "$OUT_DIR"/*.so
	for so in "${CORES_WANTED[@]}"; do
		cp -f "$PERSIST_OUT/$so" "$OUT_DIR/"
	done
	chmod a+r "$OUT_DIR"/*.so || true
	ls -la "$OUT_DIR"
	exit 0
fi

build_one() {
	local name="$1"
	local dir="$2"
	local makefile="$3"
	local so_name="$4"
	local extra="${5:-}"

	if [ -f "$PERSIST_OUT/$so_name" ]; then
		echo "==> $name deja en cache ($so_name)"
		cp -f "$PERSIST_OUT/$so_name" "$OUT_DIR/$so_name"
		return 0
	fi

	echo "==> Building $name"
	if [ ! -d "$CORE_CACHE/$dir" ]; then
		echo "Core source manquant: $CORE_CACHE/$dir" >&2
		return 1
	fi
	(
		cd "$CORE_CACHE/$dir"
		make -f "$makefile" clean >/dev/null 2>&1 || true
		# shellcheck disable=SC2086
		make -f "$makefile" -j"$(nproc)" \
			platform=unix \
			CC="$CC" CXX="$CXX" \
			$extra
		src=$(find . -maxdepth 3 -name "$so_name" | head -1)
		if [ -z "$src" ]; then
			src=$(find . -maxdepth 3 -name '*_libretro.so' | head -1)
		fi
		if [ -z "$src" ]; then
			echo "Echec: $so_name introuvable apres build $name" >&2
			exit 1
		fi
		cp -f "$src" "$OUT_DIR/$so_name"
		"$STRIP" --strip-unneeded "$OUT_DIR/$so_name" || true
		echo "    -> $OUT_DIR/$so_name ($(du -h "$OUT_DIR/$so_name" | cut -f1))"
	)
}

# Gambatte (GBC)
build_one gambatte gambatte-libretro Makefile.libretro gambatte_libretro.so

# FCEUmm (NES)
build_one fceumm libretro-fceumm Makefile.libretro fceumm_libretro.so

# Snes9x 2005
build_one snes9x2005 snes9x2005 Makefile snes9x2005_libretro.so

# PicoDrive (Megadrive)
build_one picodrive picodrive Makefile.libretro picodrive_libretro.so "TARGET=picodrive_libretro.so"

# mGBA (GBA)
build_one mgba mgba Makefile.libretro mgba_libretro.so

# PCSX ReARMed (PSX) — auto DYNAREC=ari64 / GPU neon sur aarch64
build_one pcsx_rearmed pcsx_rearmed Makefile.libretro pcsx_rearmed_libretro.so

mkdir -p "$PERSIST_OUT"
for so in "${CORES_WANTED[@]}"; do
	if [ -f "$OUT_DIR/$so" ]; then
		cp -f "$OUT_DIR/$so" "$PERSIST_OUT/"
	fi
done
echo "Cores prets dans $OUT_DIR"
ls -la "$OUT_DIR"
