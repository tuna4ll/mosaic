#!/bin/sh
# installs the latest mosaic release:
#   curl -fsSL https://github.com/tuna4ll/mosaic/releases/latest/download/install.sh | sh
# PREFIX (default /usr/local) and VERSION (default latest, e.g. v0.1.0) can be set in the environment.
set -eu

REPO=tuna4ll/mosaic
PREFIX=${PREFIX:-/usr/local}
VERSION=${VERSION:-latest}
NAME=mosaic-linux-x86_64

if [ "$(uname -s) $(uname -m)" != "Linux x86_64" ]; then
	echo "mosaic: prebuilt binaries exist only for linux x86_64; build from source: https://github.com/$REPO" >&2
	exit 1
fi

if [ "$VERSION" = latest ]; then
	base=https://github.com/$REPO/releases/latest/download
else
	base=https://github.com/$REPO/releases/download/$VERSION
fi

sudo=
[ "$(id -u)" -eq 0 ] || sudo=sudo

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

echo "downloading mosaic ($VERSION)..."
curl -fsSL -O "$base/$NAME.tar.gz" -O "$base/SHA256SUMS"
sha256sum -c SHA256SUMS >/dev/null || { echo "mosaic: checksum mismatch, aborting" >&2; exit 1; }
tar xzf "$NAME.tar.gz"

$sudo install -d "$PREFIX/bin" /usr/share/xsessions
$sudo install -m 755 "$NAME/mosaic" "$NAME/mosaic-panel" "$NAME/mosaic-launcher" "$NAME/mosaic-files" "$PREFIX/bin/"
# display managers only read /usr/share/xsessions and may not have PREFIX/bin on PATH
sed "s|=mosaic\$|=$PREFIX/bin/mosaic|" "$NAME/mosaic.desktop" > mosaic.desktop
$sudo install -m 644 mosaic.desktop /usr/share/xsessions/mosaic.desktop

if ldd "$PREFIX/bin/mosaic" | grep -q 'not found'; then
	echo "mosaic: missing libraries, install libx11, libxft and imlib2:" >&2
	ldd "$PREFIX/bin/mosaic" | grep 'not found' >&2
fi

echo "mosaic installed to $PREFIX/bin; pick \"Mosaic\" at your login screen."
