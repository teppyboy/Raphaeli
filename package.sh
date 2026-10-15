#!/bin/bash
# package.sh: assemble dist/ release from current build outputs and zip it.
# Build outputs stay in their build dirs (xkpi/out, out/); dist/ is a packaging step.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=${1:-1.0.0}
ARCH=x86_64
NAME="Raphaeli-$VERSION-$ARCH"
STAGE="dist/$NAME"

[ -d xkpi/out/Raphaeli.kext ] || { echo "missing xkpi/out/Raphaeli.kext - run xkpi/link.sh first" >&2; exit 1; }
[ -d out/usr/lib ] || { echo "missing out/usr/lib - build libdrm/RADV first" >&2; exit 1; }

rm -rf "$STAGE"
mkdir -p "$STAGE"/{kext,usr/lib,firmware/amdgpu,tools/fw}

ditto xkpi/out/Raphaeli.kext "$STAGE/kext/Raphaeli.kext"
cp out/usr/lib/*.dylib out/usr/lib/radeon_icd.x86_64.json "$STAGE/usr/lib/" 2>/dev/null || \
cp out/usr/lib/*.dylib "$STAGE/usr/lib/"
cp firmware/amdgpu/*.bin "$STAGE/firmware/amdgpu/"
cp xkpi/install.sh xkpi/oc-install.py xkpi/oc-install.sh "$STAGE/tools/"
cp xkpi/fw/stage.sh xkpi/fw/README.md "$STAGE/tools/fw/"
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
