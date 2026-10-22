#!/bin/bash
# package.sh: assemble dist/ release from current build outputs and zip it.
# Build outputs stay in their build dirs (out/, dist/ is a packaging step).
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
cd "$R"

# Bleeding edge: name releases by commit hash, not a version number.
HASH=$(git rev-parse --short HEAD)
VERSION=$HASH
VERSION_SET=0
TARGET_SELECTOR=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target)
      shift
      [ "$#" -gt 0 ] || { echo "package.sh: --target requires sequoia, tahoe, or all" >&2; exit 1; }
      [ -z "$TARGET_SELECTOR" ] || { echo "package.sh: --target specified more than once" >&2; exit 1; }
      TARGET_SELECTOR=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
      case "$TARGET_SELECTOR" in
        sequoia|tahoe|all) ;;
        *) echo "package.sh: unsupported target '$1' (use sequoia, tahoe, or all)" >&2; exit 1 ;;
      esac
      ;;
    --target=*)
      [ -z "$TARGET_SELECTOR" ] || { echo "package.sh: --target specified more than once" >&2; exit 1; }
      TARGET_SELECTOR=$(printf '%s' "${1#--target=}" | tr '[:upper:]' '[:lower:]')
      case "$TARGET_SELECTOR" in
        sequoia|tahoe|all) ;;
        *) echo "package.sh: unsupported target '${1#--target=}' (use sequoia, tahoe, or all)" >&2; exit 1 ;;
      esac
      ;;
    --help|-h)
      echo "usage: scripts/package.sh [version] [--target sequoia|tahoe|all]"
      exit 0
      ;;
    --*)
      echo "package.sh: unknown option $1" >&2
      exit 1
      ;;
    *)
      [ "$VERSION_SET" = 0 ] || { echo "package.sh: version specified more than once" >&2; exit 1; }
      VERSION=$1
      VERSION_SET=1
      ;;
  esac
  shift
done
[ -n "$TARGET_SELECTOR" ] || {
  echo "package.sh: --target is required for release packaging (sequoia, tahoe, or all)" >&2
  exit 1
}
case "$TARGET_SELECTOR" in
  sequoia)
    "$R/scripts/target-preflight.sh" sequoia "$R/Raphaeli/Kernel/Accel/upstream/SOURCE.lock" || exit 1
    TARGET_NAMES="Sequoia"
    INSTALL_TARGET="the Sequoia target bundle"
    INSTALL_OC_STEP='`python3 tools/oc-install.py /path/to/EFI --add --target sequoia` (macOS 15)'
    INSTALL_RECOVERY_STEP='`./tools/recovery-install.sh "/Volumes/Macintosh HD" --target sequoia --apply`'
    INSTALL_DIRECT_KEXT='target/Sequoia/Raphaeli.kext'
    ;;
  tahoe)
    "$R/scripts/target-preflight.sh" tahoe "$R/Raphaeli/Kernel/Accel/upstream/SOURCE.lock" || exit 1
    TARGET_NAMES="Tahoe"
    INSTALL_TARGET="the Tahoe target bundle"
    INSTALL_OC_STEP='`python3 tools/oc-install.py /path/to/EFI --add --target tahoe` (macOS 26)'
    INSTALL_RECOVERY_STEP='`./tools/recovery-install.sh "/Volumes/Macintosh HD" --target tahoe --apply`'
    INSTALL_DIRECT_KEXT='target/Tahoe/Raphaeli.kext'
    ;;
  all)
    "$R/scripts/target-preflight.sh" sequoia "$R/Raphaeli/Kernel/Accel/upstream/SOURCE.lock" || exit 1
    "$R/scripts/target-preflight.sh" tahoe "$R/Raphaeli/Kernel/Accel/upstream/SOURCE.lock" || exit 1
    TARGET_NAMES="Sequoia Tahoe"
    INSTALL_TARGET="both target bundles"
    INSTALL_OC_STEP='`python3 tools/oc-install.py /path/to/EFI --add --target sequoia` (macOS 15) or `python3 tools/oc-install.py /path/to/EFI --add --target tahoe` (macOS 26)'
    INSTALL_RECOVERY_STEP='`./tools/recovery-install.sh "/Volumes/Macintosh HD" --target sequoia --apply` (macOS 15) or `./tools/recovery-install.sh "/Volumes/Macintosh HD" --target tahoe --apply` (macOS 26)'
    INSTALL_DIRECT_KEXT='target/Sequoia/Raphaeli.kext or target/Tahoe/Raphaeli.kext'
    ;;
esac
ARCH=x86_64
NAME="Raphaeli-$VERSION-$ARCH"
STAGE="dist/$NAME"

validate_target_kext() {
  target_kext=$1
  plist="$target_kext/Contents/Info.plist"
  [ -d "$target_kext/Contents" ] && [ -f "$plist" ] || {
    echo "$target_kext is not a kext bundle" >&2
    exit 1
  }
  plutil -lint "$plist" >/dev/null || {
    echo "$target_kext has an invalid Info.plist" >&2
    exit 1
  }
  bundle_id=$(plutil -extract CFBundleIdentifier raw "$plist" 2>/dev/null) || {
    echo "$target_kext has no CFBundleIdentifier" >&2
    exit 1
  }
  [ "$bundle_id" = "me.tretrauit.raphaeli" ] || {
    echo "$target_kext has unexpected bundle id '$bundle_id'" >&2
    exit 1
  }
  executable=$(plutil -extract CFBundleExecutable raw "$plist" 2>/dev/null) || {
    echo "$target_kext has no CFBundleExecutable" >&2
    exit 1
  }
  case "$executable" in
    ''|*/*)
      echo "$target_kext has invalid executable '$executable'" >&2
      exit 1
      ;;
  esac
  executable_path="$target_kext/Contents/MacOS/$executable"
  [ -f "$executable_path" ] && [ -x "$executable_path" ] || {
    echo "$target_kext executable is missing or not executable: $executable_path" >&2
    exit 1
  }

  # Convert through plutil, rather than grepping the source plist: this catches
  # stale vendor-wide personalities regardless of their XML formatting.
  plist_xml=$(mktemp "${TMPDIR:-/tmp}/raphaeli-package-plist.XXXXXX")
  if ! plutil -convert xml1 -o "$plist_xml" "$plist"; then
    rm -f "$plist_xml"
    echo "$target_kext Info.plist could not be converted" >&2
    exit 1
  fi
  if ! awk '
    index($0, "<key>IOPCIPrimaryMatch</key>") { in_match = 1; count++; next }
    in_match {
      if (index($0, "<string>0x000015bf&amp;0xffffffff</string>") == 0) bad = 1
      in_match = 0
    }
    END { if (count == 0 || bad) exit 1 }
  ' "$plist_xml"; then
    rm -f "$plist_xml"
    echo "$target_kext has PCI matching outside validated 0x15bf scope" >&2
    exit 1
  fi
  rm -f "$plist_xml"
}

for target_name in $TARGET_NAMES; do
  validate_target_kext "out/target/$target_name/Raphaeli.kext"
done
[ -d out/usr/lib ] || { echo "missing out/usr/lib - build libdrm/RADV first" >&2; exit 1; }
for userspace_file in libdrm.2.dylib libdrm_amdgpu.1.dylib libvulkan_radeon.dylib; do
  [ -f "out/usr/lib/$userspace_file" ] || {
    echo "missing out/usr/lib/$userspace_file - build libdrm/RADV first" >&2
    exit 1
  }
done
[ -d firmware/amdgpu ] || { echo "missing firmware/amdgpu - stage firmware first" >&2; exit 1; }
REQUIRED_FW_NAMES="
 gc_11_0_1_pfp.bin gc_11_0_1_me.bin gc_11_0_1_rlc.bin
 gc_11_0_1_mec.bin gc_11_0_1_imu.bin gc_11_0_1_mes1.bin
 sdma_6_0_2.bin psp_13_0_11_toc.bin psp_13_0_11_ta.bin
 vcn_4_0_2.bin dcn_3_1_4_dmcub.bin
"
for firmware_name in $REQUIRED_FW_NAMES; do
  [ -f "firmware/amdgpu/$firmware_name" ] || {
    echo "missing firmware/amdgpu/$firmware_name - stage firmware first" >&2
    exit 1
  }
done

rm -rf "$STAGE"
for target_name in $TARGET_NAMES; do
  mkdir -p "$STAGE/target/$target_name"
done
mkdir -p "$STAGE"/{usr/lib,firmware/amdgpu,tools/fw}

stage_kext() {
  source=$1
  destination=$2
  ditto "$source" "$destination"
  # Stamp each staged kext with the commit it was built from.
  plutil -replace CFBundleVersion -string "$HASH" "$destination/Contents/Info.plist"
  plutil -replace CFBundleShortVersionString -string "$HASH" "$destination/Contents/Info.plist"
}
for target_name in $TARGET_NAMES; do
  target_kext="out/target/$target_name/Raphaeli.kext"
  stage_kext "$target_kext" "$STAGE/target/$target_name/Raphaeli.kext"
done
cp out/usr/lib/*.dylib "$STAGE/usr/lib/"
[ -s out/usr/lib/radeon_icd.x86_64.json ] || {
  echo "missing out/usr/lib/radeon_icd.x86_64.json - build userspace first" >&2
  exit 1
}
cp out/usr/lib/radeon_icd.x86_64.json "$STAGE/usr/lib/"
cp firmware/amdgpu/*.bin "$STAGE/firmware/amdgpu/"
cp scripts/install.sh scripts/recovery-install.sh scripts/collect-recovery.sh scripts/oc-stage-graphics.py scripts/oc-install.py scripts/oc-install.sh scripts/target-preflight.sh "$STAGE/tools/"
cp Raphaeli/Kernel/Accel/upstream/SOURCE.lock "$STAGE/tools/"
cp Raphaeli/Firmware/stage.sh Raphaeli/Firmware/README.md "$STAGE/tools/fw/"
cp README.md "$STAGE/"

cat > "$STAGE/INSTALL.md" <<'EOF'
# Raphaeli install (AMD Radeon 780M / gfx1103, PCI 0x15bf)

Unsigned kext - requires AMFI + Secure Boot disabled (Hackintosh).

## OpenCore (recommended, black-screen-safe)
This release contains @INSTALL_TARGET@. Select the kext matching the target OS explicitly:
1. @INSTALL_OC_STEP@
2. `python3 tools/oc-install.py /path/to/EFI --enable` # adds raphaeli-amd=1 boot-arg
3. Reboot. Recovery: `--disable` or set Enabled=false in config.plist.

For a mounted target system volume, pass `--system-root /Volumes/Macintosh\ HD` to
`--add` when selecting from ProductVersion.plist. Do not select based on the host OS.

## Recovery diagnostics
From Recovery Terminal, with the USB/EFI volumes already mounted:
`bash tools/collect-recovery.sh /Volumes/USB/raphaeli-diagnostics /Volumes/EFI`
Creates a `.tar.gz` with the running Recovery build, Boot KC, OpenCore logs,
and EFI kext hash. No config/NVRAM edits. Review logs for identifiers before sharing.

## Experimental Tahoe Recovery dependency staging
On a macOS host, validate the mounted Recovery image against its exact-build KDK:
`python3 tools/oc-stage-graphics.py /Volumes/EFI "/Volumes/macOS Base System" /path/to/KDK`
Defaults to dry-run; `--apply` stages matching Apple graphics dependencies before
Raphaeli and backs up config.plist. Build, x86_64 UUID, and version must match.
Injection-tested only: target runtime is unverified. Restore the printed backup
if boot fails; revalidate after OS/Recovery updates. Never mix Sequoia/Tahoe kexts.

## Direct (kextload route, needs matching KDK on target)
1. `sudo ./tools/install.sh @INSTALL_DIRECT_KEXT@`        # select the matching target bundle
2. `sudo ./tools/install.sh --apply`                   # adds raphaeli-amd=1
- target bundle selection is explicit; firmware blobs are shared

## Userspace (Vulkan)
- `usr/lib/libvulkan_radeon.dylib` + `usr/lib/radeon_icd.x86_64.json`
- point VK_ICD_FILENAMES at the json; libdrm libs are its dependencies

## Installing from macOS Recovery
For when the normal volume's WindowServer crashes and kextload is impossible.
Boot into RecoveryOS, open Terminal:
1. @INSTALL_RECOVERY_STEP@
   (auto-detects the volume if unambiguous; `--target sequoia|tahoe` selects
   the matching kext; add `--dry-run` to preview;
   plain bash 3.2 + coreutils, exactly what RecoveryOS ships)
- APFS: tries `mount -uw`; dylibs go to `Library/Raphaeli/usr/lib/` (Sealed
  System Volume makes `/usr/lib` unwritable) and the ICD json is written to
  `usr/local/share/vulkan/icd.d/` with an absolute `library_path`
- OC-injected setups: detects `EFI/OC/config.plist` and skips the kext copy +
  auxKC (OC injects); firmware/userspace/boot-args only. config.plist is never
  edited here - use `oc-install.py` from the booted system
- `--apply` sets `raphaeli-amd=1` in NVRAM; `--uninstall` removes it, the
  `raphaeli-gpu-attaching` guard marker, and everything installed above
- If no auxKC could be built (no matching KDK in Recovery), finish with
  `sudo ./tools/install.sh @INSTALL_DIRECT_KEXT@ --apply` from the booted system
- Vulkan loader hint if discovery fails: `VK_DRIVER_FILES=/usr/local/share/vulkan/icd.d/radeon_icd.x86_64.json`
EOF
sed -i.bak \
  -e "s|@INSTALL_TARGET@|$INSTALL_TARGET|g" \
  -e "s|@INSTALL_OC_STEP@|$INSTALL_OC_STEP|g" \
  -e "s|@INSTALL_RECOVERY_STEP@|$INSTALL_RECOVERY_STEP|g" \
  -e "s|@INSTALL_DIRECT_KEXT@|$INSTALL_DIRECT_KEXT|g" \
  "$STAGE/INSTALL.md"
rm -f "$STAGE/INSTALL.md.bak"

# Write and verify a temporary archive; the final ZIP appears only after zip and
# integrity checks succeed. An older release remains intact on preflight failure.
ZIP_TMP="$NAME.zip.tmp.$$"
rm -f "dist/$ZIP_TMP"
( cd dist && zip -qr "$ZIP_TMP" "$NAME" && unzip -tq "$ZIP_TMP" && mv -f "$ZIP_TMP" "$NAME.zip" )
echo "dist/$NAME.zip:"; ls -la "dist/$NAME.zip"

# native installer (userspace + firmware only - the zip covers the kext route)
# lands in dist/, never inside the zip
./scripts/make-pkg.sh dist
