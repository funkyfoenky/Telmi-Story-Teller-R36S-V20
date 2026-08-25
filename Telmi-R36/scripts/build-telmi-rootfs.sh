#!/usr/bin/env bash
# Compile le rootfs TelmiOS (Buildroot + apps Telmi)
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TELMI_R36="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$(cd "$TELMI_R36/.." && pwd)"
BUILDROOT_DIR="${BUILDROOT_DIR:-$HOME/r36s-helloworld-build/buildroot-r36s}"
BUILDROOT_REPO="https://github.com/AndreRenaud/buildroot-r36s.git"
BUILDROOT_BRANCH="r36s"
JOBS="${JOBS:-$(nproc)}"
export BR2_EXTERNAL="$TELMI_R36/external/telmi-r36"

echo "==> Telmi-R36 : $TELMI_R36"
echo "==> Buildroot : $BUILDROOT_DIR"

bash "$SCRIPT_DIR/fetch-telmi-assets.sh"

if [[ ! -d "$BUILDROOT_DIR/.git" ]]; then
	git clone --branch "$BUILDROOT_BRANCH" --depth 1 "$BUILDROOT_REPO" "$BUILDROOT_DIR"
fi

cp "$TELMI_R36/buildroot/configs/telmi_r36_os_defconfig" "$BUILDROOT_DIR/configs/"

# SDL2_mixer : activer le decodeur MP3 integre (drmp3) — requis pour les histoires
SDL2_MIXER_MK="$BUILDROOT_DIR/package/sdl2_mixer/sdl2_mixer.mk"
if [[ -f "$SDL2_MIXER_MK" ]] && grep -q 'SDL2_MIXER_CONF_OPTS = --disable-music-mp3' "$SDL2_MIXER_MK"; then
	echo "==> Patch sdl2_mixer : enable-music-mp3-drmp3"
	sed -i 's/SDL2_MIXER_CONF_OPTS = --disable-music-mp3/SDL2_MIXER_CONF_OPTS = --enable-music-mp3-drmp3/' "$SDL2_MIXER_MK"
fi

OVERLAY_DST="$BUILDROOT_DIR/board/telmi-r36/overlay"
rm -rf "$BUILDROOT_DIR/board/telmi-r36"
mkdir -p "$OVERLAY_DST"
rsync -a "$TELMI_R36/overlay/" "$OVERLAY_DST/"
find "$OVERLAY_DST" -type f \( -name '*.sh' -o -name 'fstab' -o -name 'S*' -o -name 'asound.conf' \) -exec sed -i 's/\r$//' {} +
chmod +x "$OVERLAY_DST/etc/init.d/S05boot" \
	"$OVERLAY_DST/etc/init.d/S06telmi-content" \
	"$OVERLAY_DST/etc/init.d/S07telmi-audio" \
	"$OVERLAY_DST/etc/init.d/S98telmi-fb" \
	"$OVERLAY_DST/etc/init.d/S99telmi" \
	"$OVERLAY_DST/opt/telmi/bin/telmi-runtime.sh" \
	"$OVERLAY_DST/opt/telmi/bin/telmi-mount-content.sh"
make -C "$BUILDROOT_DIR" telmi_r36_os_defconfig

# Mesa peut rester en cache sans swrast apres changement de defconfig.
if grep -q 'BR2_PACKAGE_MESA3D_GALLIUM_DRIVER_SWRAST=y' "$BUILDROOT_DIR/.config" && \
	[[ ! -f "$BUILDROOT_DIR/output/target/usr/lib/dri/kms_swrast_dri.so" ]]; then
	echo "==> Rebuild Mesa (ajout swrast/kms_swrast)..."
	make -C "$BUILDROOT_DIR" mesa3d-dirclean
fi

# Forcer rebuild audio si ALSA / MP3 viennent d'etre actives
if ! grep -q 'enable-music-mp3-drmp3' "$BUILDROOT_DIR"/output/build/sdl2_mixer-*/config.log 2>/dev/null; then
	echo "==> Rebuild sdl2_mixer (MP3 drmp3)..."
	make -C "$BUILDROOT_DIR" sdl2_mixer-dirclean || true
fi
if [[ ! -f "$BUILDROOT_DIR/output/target/usr/lib/libasound.so.2" ]] && \
	[[ ! -f "$BUILDROOT_DIR/output/target/usr/lib/libasound.so" ]]; then
	echo "==> Rebuild SDL2 avec ALSA..."
	make -C "$BUILDROOT_DIR" sdl2-dirclean || true
fi

# Buildroot ne supprime pas les fichiers d'un ancien defconfig (Hello World).
rm -f "$BUILDROOT_DIR/output/target/usr/bin/hello-world" \
	"$BUILDROOT_DIR/output/target/etc/init.d/S98bootscreen" \
	"$BUILDROOT_DIR/output/target/etc/init.d/S99userapp"
rm -f "$BUILDROOT_DIR/output/target/var/log/hello-world.log"

echo "==> Rebuild binaires Telmi..."
make -C "$BUILDROOT_DIR" telmi-r36s-dirclean

# QUICK=1 : package telmi seulement (~1-2 min), sinon make complet.
if [[ "${QUICK:-0}" == "1" ]]; then
	echo "==> Mode QUICK : make telmi-r36s seulement"
	make -C "$BUILDROOT_DIR" telmi-r36s -j"$JOBS"
	make -C "$BUILDROOT_DIR" -j"$JOBS"
else
	make -C "$BUILDROOT_DIR" -j"$JOBS"
fi

mkdir -p "$TELMI_R36/output"
cp -f "$BUILDROOT_DIR/output/images/rootfs.tar" "$TELMI_R36/output/rootfs.tar"
echo ""
echo "Rootfs : $TELMI_R36/output/rootfs.tar"
echo "Astuce patch rapide image :"
echo "  bash Telmi-R36/scripts/quick-update-telmi.sh"
