#!/bin/bash
# make-pkg.sh: build a native macOS .pkg installer (pkgbuild + productbuild) for Raphaeli.
#
# Payload:
#   1. usr-local:  /usr/local/share/vulkan/icd.d/radeon_icd.x86_64.json
#                  /Library/Raphaeli/usr/lib/{libdrm.2.dylib,libdrm_amdgpu.1.dylib,libvulkan_radeon.dylib}
#   2. framework:  /Library/Raphaeli/firmware/amdgpu/*.bin
#   3. kext (--with-kext): /Library/Extensions/Raphaeli.kext (root:wheel via postinstall chown)
#
# The postinstall script does NOT touch nvram boot-args (oc-install.py / recovery-install.sh
# own that) and does NOT run kmutil: auxKC rebuild (kmutil install/rebuild) must happen on
# the booted target system, not from RecoveryOS.
#
# Usage: scripts/make-pkg.sh [out-dir] [--with-kext]     # default out-dir: dist
#   KEXT source: out-disp/Raphaeli.kext (override with RAPHAELI_KEXT=<dir>, same as package.sh)
#
# Unsigned pkg: `installer -pkg <pkg> -target /Volumes/<vol>` accepts unsigned pkgs from CLI;
# double-clicking an unsigned pkg in GUI triggers Gatekeeper ("unidentified developer") and
# needs right-click > Open or xattr -d com.apple.quarantine after download.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
cd "$R"

OUT_DIR=dist
WITH_KEXT=0
for arg in "$@"; do
  case $arg in
    --with-kext) WITH_KEXT=1 ;;
    *) OUT_DIR=$arg ;;
  esac
done

HASH=$(git rev-parse --short HEAD)
PKG="$OUT_DIR/Raphaeli-$HASH-x86_64.pkg"
KEXT=${RAPHAELI_KEXT:-out-disp/Raphaeli.kext}

[ -d out/usr/lib ] || { echo "missing out/usr/lib - build libdrm/RADV first" >&2; exit 1; }
[ -d firmware/amdgpu ] || { echo "missing firmware/amdgpu" >&2; exit 1; }
if [ $WITH_KEXT = 1 ]; then
  [ -d "$KEXT" ] || { echo "missing $KEXT - run scripts/link.sh first" >&2; exit 1; }
fi
for tool in pkgbuild productbuild plutil install_name_tool; do
  command -v $tool >/dev/null || { echo "missing $tool" >&2; exit 1; }
done

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE"/{usr-local/usr/local/share/vulkan/icd.d,usr-local/Library/Raphaeli/usr/lib,framework/Library/Raphaeli/firmware/amdgpu,scripts,components}

# --- component 1: userspace ---------------------------------------------------
# ICD json ships with an absolute library_path (loader-agnostic, matches install.sh layout).
cat > "$STAGE/usr-local/usr/local/share/vulkan/icd.d/radeon_icd.x86_64.json" <<'EOF'
{
    "ICD": {
        "api_version": "1.4.363",
        "library_arch": "64",
        "library_path": "/Library/Raphaeli/usr/lib/libvulkan_radeon.dylib"
    },
    "file_format_version": "1.0.1"
}
EOF
LIBDST="$STAGE/usr-local/Library/Raphaeli/usr/lib"
# dylib names are the darwin meson ones (libdrm.2.dylib / libdrm_amdgpu.1.dylib), not .so.N;
# the .dylib convenience symlinks in out/usr/lib are not needed (nothing loads by that name).
for f in libdrm.2.dylib libdrm_amdgpu.1.dylib libvulkan_radeon.dylib; do
  cp out/usr/lib/$f "$LIBDST/$f"
done
# build-tree install names are absolute dev-host paths; rewrite to @loader_path so the
# payload dlopens from /Library/Raphaeli/usr/lib on any machine.
OUTLIB=$(cd out/usr/lib && pwd)
install_name_tool -id @loader_path/libdrm.2.dylib "$LIBDST/libdrm.2.dylib"
install_name_tool -id @loader_path/libdrm_amdgpu.1.dylib "$LIBDST/libdrm_amdgpu.1.dylib"
install_name_tool -change "$OUTLIB/libdrm.2.dylib" @loader_path/libdrm.2.dylib "$LIBDST/libdrm_amdgpu.1.dylib"
install_name_tool -id @loader_path/libvulkan_radeon.dylib "$LIBDST/libvulkan_radeon.dylib"
install_name_tool -change "$OUTLIB/libdrm_amdgpu.1.dylib" @loader_path/libdrm_amdgpu.1.dylib "$LIBDST/libvulkan_radeon.dylib"
install_name_tool -change "$OUTLIB/libdrm.2.dylib" @loader_path/libdrm.2.dylib "$LIBDST/libvulkan_radeon.dylib"

# --- component 2: firmware -----------------------------------------------------
cp firmware/amdgpu/*.bin "$STAGE/framework/Library/Raphaeli/firmware/amdgpu/"

# --- component 3: kext (optional) ---------------------------------------------
if [ $WITH_KEXT = 1 ]; then
  KEXTDST="$STAGE/kext/Library/Extensions/Raphaeli.kext"
  mkdir -p "$STAGE/kext/Library/Extensions"
  ditto "$KEXT" "$KEXTDST"
  plutil -replace CFBundleVersion -string "$HASH" "$KEXTDST/Contents/Info.plist"
  plutil -replace CFBundleShortVersionString -string "$HASH" "$KEXTDST/Contents/Info.plist"
fi

# --- postinstall (runs on target; never on Recovery reads of nvram) ------------
cat > "$STAGE/scripts/postinstall" <<'EOF'
#!/bin/bash
# kext payloads from a user-owned tree keep their uid/gid; kmutil requires root:wheel.
if [ -d /Library/Extensions/Raphaeli.kext ]; then
  chown -R root:wheel /Library/Extensions/Raphaeli.kext
fi
echo "Raphaeli installed:"
echo "  ICD:    /usr/local/share/vulkan/icd.d/radeon_icd.x86_64.json"
echo "  libs:   /Library/Raphaeli/usr/lib/"
echo "  fw:     /Library/Raphaeli/firmware/amdgpu/"
[ -d /Library/Extensions/Raphaeli.kext ] && echo "  kext:   /Library/Extensions/Raphaeli.kext (root:wheel)"
echo "  note:   auxKC rebuild (kmutil) must run on the booted system, not Recovery;"
echo "          boot-args (raphaeli-amd=1) are managed by oc-install.py / recovery-install.sh."
exit 0
EOF
chmod 755 "$STAGE/scripts/postinstall"

# --- components ----------------------------------------------------------------
pkgbuild --root "$STAGE/usr-local" \
  --identifier me.tretrauit.raphaeli.pkg.usrlocal --version "$HASH" \
  --scripts "$STAGE/scripts" \
  "$STAGE/components/usr-local.pkg" >/dev/null

pkgbuild --root "$STAGE/framework" \
  --identifier me.tretrauit.raphaeli.pkg.framework --version "$HASH" \
  "$STAGE/components/framework.pkg" >/dev/null

if [ $WITH_KEXT = 1 ]; then
  # preserve source ownership; postinstall chown enforces root:wheel on the target.
  pkgbuild --root "$STAGE/kext" \
    --identifier me.tretrauit.raphaeli.pkg.kext --version "$HASH" \
    --ownership preserve \
    "$STAGE/components/kext.pkg" >/dev/null
fi

# --- distribution --------------------------------------------------------------
cat > "$STAGE/distribution.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
    <title>Raphaeli</title>
    <options customize="never" allow-external-scripts="false" require-scripts="false"/>
    <domains enable_anywhere="true" enable_currentUserHome="false" enable_localSystem="true"/>
    <os-version min="14.0"/>
    <choices-outline>
        <line choice="usrlocal"/>
        <line choice="framework"/>
        <line choice="kext"/>
    </choices-outline>
    <choice id="usrlocal" title="Userspace (Vulkan ICD + libdrm)">
        <pkg-ref id="me.tretrauit.raphaeli.pkg.usrlocal"/>
    </choice>
    <choice id="framework" title="Firmware (amdgpu)">
        <pkg-ref id="me.tretrauit.raphaeli.pkg.framework"/>
    </choice>
    <choice id="kext" title="Kernel extension">
        <pkg-ref id="me.tretrauit.raphaeli.pkg.kext"/>
    </choice>
    <pkg-ref id="me.tretrauit.raphaeli.pkg.usrlocal">usr-local.pkg</pkg-ref>
    <pkg-ref id="me.tretrauit.raphaeli.pkg.framework">framework.pkg</pkg-ref>
    <pkg-ref id="me.tretrauit.raphaeli.pkg.kext">kext.pkg</pkg-ref>
</installer-gui-script>
EOF
if [ $WITH_KEXT != 1 ]; then
  # kext choice references a pkg that isn't bundled; drop it.
  python3 - "$STAGE/distribution.xml" <<'PYEOF'
import sys, re
p = sys.argv[1]
s = open(p).read()
s = s.replace('        <line choice="kext"/>\n', '')
s = s.replace('    <choice id="kext" title="Kernel extension">\n        <pkg-ref id="me.tretrauit.raphaeli.pkg.kext"/>\n    </choice>\n', '')
s = s.replace('    <pkg-ref id="me.tretrauit.raphaeli.pkg.kext">kext.pkg</pkg-ref>\n', '')
open(p, 'w').write(s)
PYEOF
fi

mkdir -p "$OUT_DIR"
productbuild --distribution "$STAGE/distribution.xml" \
  --package-path "$STAGE/components" \
  --identifier me.tretrauit.raphaeli.pkg --version "$HASH" \
  "$PKG" >/dev/null

echo "$PKG:"
ls -la "$PKG"
