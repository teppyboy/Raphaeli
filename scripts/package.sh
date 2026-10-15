#!/bin/bash
# package.sh: assemble dist/ release from current build outputs and zip it.
# Build outputs stay in their build dirs (out/, dist/ is a packaging step).
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
cd "$R"

# Bleeding edge: name releases by commit hash, not a version number.
HASH=$(git rev-parse --short HEAD)
VERSION=${1:-$HASH}
ARCH=x86_64
NAME="Raphaeli-$VERSION-$ARCH"
STAGE="dist/$NAME"

# Kext source dir override: RAPHAELI_KEXT=<dir> ./package.sh — needed when out/Raphaeli.kext is
# root:wheel (post-chown for kmutil) and a fresh user-owned link lives elsewhere (e.g. out-disp).
KEXT=${RAPHAELI_KEXT:-out/Raphaeli.kext}
[ -d "$KEXT" ] || { echo "missing $KEXT - run scripts/link.sh first" >&2; exit 1; }
[ -d out/usr/lib ] || { echo "missing out/usr/lib - build libdrm/RADV first" >&2; exit 1; }

rm -rf "$STAGE"
mkdir -p "$STAGE"/{kext,usr/lib,firmware/amdgpu,tools/fw}

ditto "$KEXT" "$STAGE/kext/Raphaeli.kext"
# stamp the staged kext with the commit it was built from
plutil -replace CFBundleVersion -string "$HASH" "$STAGE/kext/Raphaeli.kext/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$HASH" "$STAGE/kext/Raphaeli.kext/Contents/Info.plist"
cp out/usr/lib/*.dylib out/usr/lib/radeon_icd.x86_64.json "$STAGE/usr/lib/" 2>/dev/null || \
cp out/usr/lib/*.dylib "$STAGE/usr/lib/"
cp firmware/amdgpu/*.bin "$STAGE/firmware/amdgpu/"
cp scripts/install.sh scripts/oc-install.py scripts/oc-install.sh "$STAGE/tools/"
cp Raphaeli/Firmware/stage.sh Raphaeli/Firmware/README.md "$STAGE/tools/fw/"
cp README.md "$STAGE/"

cat > "$STAGE/INSTALL.md" <<'EOF'
# Raphaeli install (AMD Radeon 780M / gfx1103, PCI 0x15bf)

Unsigned kext - requires AMFI + Secure Boot disabled (Hackintosh).

## OpenCore (recommended, black-screen-safe)
1. `python3 tools/oc-install.py /path/to/EFI --add`   # loads inert, display untouched
2. `python3 tools/oc-install.py /path/to/EFI --enable` # adds raphaeli-amd=1 boot-arg
3. Reboot. Recovery: `--disable` or set Enabled=false in config.plist.

## Direct (kextload route, needs matching KDK on target)
1. `sudo ./tools/install.sh kext/Raphaeli.kext`        # installs kext + firmware + auxKC
2. `sudo ./tools/install.sh --apply`                   # adds raphaeli-amd=1
- kext/firmware blobs are staged to /Library/Raphaeli/firmware automatically

## Userspace (Vulkan)
- `usr/lib/libvulkan_radeon.dylib` + `usr/lib/radeon_icd.x86_64.json`
- point VK_ICD_FILENAMES at the json; libdrm libs are its dependencies
EOF

( cd dist && rm -f "$NAME.zip" && zip -qr "$NAME.zip" "$NAME" )
echo "dist/$NAME.zip:"; ls -la "dist/$NAME.zip"
