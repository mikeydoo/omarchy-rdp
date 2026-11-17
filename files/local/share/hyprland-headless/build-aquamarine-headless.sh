#!/bin/sh
# Build libaquamarine with the headless-render-node patch, matching the installed aquamarine
# version, into ./lib (~/.local/share/hyprland-headless/lib). The system library is not
# touched; only the headless remote session loads this copy (via LD_LIBRARY_PATH).
#
# Normally run through rebuild-if-stale.sh (by hyprland-remote.service before every start,
# and by the Omarchy post-update hook), not by hand.
#
# Exit codes: 0 built; 75 download failed (try again later); 1 anything else (missing
# build tools, the patch no longer applies, or the build failed: needs a person).
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
PATCH="$HERE/patches/aquamarine-headless-render-node.patch"
DEST="$HERE/lib"

for c in cmake make c++ curl tar patch pkg-config hyprwayland-scanner; do
    command -v "$c" >/dev/null || { echo "missing build tool: $c (run Repair in the Omarchy RDP panel (omarchy-rdp-ctl install))" >&2; exit 1; }
done

VERSION=$(pacman -Q aquamarine | awk '{print $2}' | sed 's/-.*//')
echo "Installed aquamarine: $VERSION"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
if ! curl -fsSL --retry 3 -o src.tar.gz \
    "https://github.com/hyprwm/aquamarine/archive/refs/tags/v$VERSION.tar.gz"; then
    echo "couldn't download aquamarine $VERSION's source (no network yet?)" >&2
    exit 75
fi
tar xzf src.tar.gz
cd "aquamarine-$VERSION"

if ! patch -p1 --dry-run < "$PATCH" >/dev/null; then
    echo "The patch does not apply to aquamarine $VERSION (written for 0.16.0, also applies to 0.15.1)." >&2
    echo "Port patches/aquamarine-headless-render-node.patch to src/backend/Headless.cpp" >&2
    echo "and src/allocator/GBM.cpp, then run Repair in the Omarchy RDP panel (omarchy-rdp-ctl install)." >&2
    exit 1
fi
patch -p1 < "$PATCH"

cmake -S . -B build -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build build -j"$(nproc)"

mkdir -p "$DEST"
rm -f "$DEST"/libaquamarine.so*
cp -a build/libaquamarine.so* "$DEST/"
echo "$VERSION" > "$DEST/AQUAMARINE_VERSION"
echo "Installed patched libaquamarine $VERSION to $DEST"
