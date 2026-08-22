# Compile les binaires Telmi (image unique multi-REV).
# Quirks V20/V30 = runtime /boot/TELMI-REV.txt — un seul code.
#
# Usage :
#   bash scripts/build-telmi-bins.sh unified
#   bash scripts/build-telmi-bins.sh unified storyTeller
#   bash scripts/build-telmi-bins.sh v20|v30   # staging separe, meme binaire
#
# Sortie :
#   staging/<profil>/opt/telmi/bin/
#   + miroir staging/opt/telmi/bin/
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TELMI_R36="$(cd "$SCRIPT_DIR/.." && pwd)"
BR="${BUILDROOT_DIR:-$HOME/r36s-helloworld-build/buildroot-r36s}"
HOST="${HOST_DIR:-$BR/output/host}"
STAGING_BR="${STAGING_DIR:-$BR/output/staging}"

PROFILE="${1:-unified}"
if [[ $# -ge 1 ]]; then
	shift
fi
TARGET="${*:-all}"

case "$PROFILE" in
	unified|v20|v30) ;;
	*)
		echo "Usage: $0 unified|v20|v30 [cible-make...]"
		echo "  Ex: $0 unified storyTeller bootScreen"
		exit 1
		;;
esac

[[ -x "$HOST/bin/aarch64-linux-gcc" ]] || {
	echo "ERREUR : toolchain introuvable ($HOST/bin/aarch64-linux-gcc)"
	exit 1
}

export PATH="$HOST/bin:$PATH"
echo "============================================================"
echo " Build Telmi bins  profil=$PROFILE (runtime REV)  cible=$TARGET"
echo " Staging : $TELMI_R36/staging/$PROFILE/opt/telmi/bin"
echo "============================================================"

# shellcheck disable=SC2086
make -C "$TELMI_R36/build" \
	TELMI_PROFILE="$PROFILE" \
	CC=aarch64-linux-gcc \
	STRIP=aarch64-linux-strip \
	HOST_DIR="$HOST" \
	EXTRA_CFLAGS="-I$STAGING_BR/usr/include -I$STAGING_BR/usr/include/SDL2" \
	EXTRA_LDFLAGS="-L$STAGING_BR/usr/lib -Wl,-rpath-link,$STAGING_BR/usr/lib" \
	$TARGET

echo "OK $TELMI_R36/staging/$PROFILE/opt/telmi/bin/"
ls -la "$TELMI_R36/staging/$PROFILE/opt/telmi/bin/" | head -20
