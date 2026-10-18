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
ARCH=x86_64
NAME="Raphaeli-$VERSION-$ARCH"
STAGE="dist/$NAME"

# Kext source dir override: RAPHAELI_KEXT=<dir> ./package.sh — needed when out/Raphaeli.kext is
# root:wheel (post-chown for kmutil) and a fresh user-owned link lives elsewhere (e.g. out-disp).
KEXT=${RAPHAELI_KEXT:-out/Raphaeli.kext}
if [ -n "$TARGET_SELECTOR" ]; then
  case "$TARGET_SELECTOR" in
    sequoia) TARGET_NAMES="Sequoia" ;;
    tahoe) TARGET_NAMES="Tahoe" ;;
    all) TARGET_NAMES="Sequoia Tahoe" ;;
  esac
  for target_name in $TARGET_NAMES; do
    target_kext="out/target/$target_name/Raphaeli.kext"
    [ -f "$target_kext/Contents/Info.plist" ] || {
      echo "$target_kext is not a kext bundle" >&2
      exit 1
    }
  done
else
  [ -f "$KEXT/Contents/Info.plist" ] || { echo "$KEXT is not a kext bundle - pass e.g. RAPHAELI_KEXT=out-disp/Raphaeli.kext" >&2; exit 1; }
fi
[ -d out/usr/lib ] || { echo "missing out/usr/lib - build libdrm/RADV first" >&2; exit 1; }
[ -d firmware/amdgpu ] || { echo "missing firmware/amdgpu - stage firmware first" >&2; exit 1; }

rm -rf "$STAGE"
if [ -n "$TARGET_SELECTOR" ]; then
  for target_name in $TARGET_NAMES; do
    mkdir -p "$STAGE/target/$target_name"
  done
else
  mkdir -p "$STAGE/kext"
fi
mkdir -p "$STAGE"/{usr/lib,firmware/amdgpu,tools/fw}

stage_kext() {
  source=$1
  destination=$2
  ditto "$source" "$destination"
  # Stamp each staged kext with the commit it was built from.
  plutil -replace CFBundleVersion -string "$HASH" "$destination/Contents/Info.plist"
  plutil -replace CFBundleShortVersionString -string "$HASH" "$destination/Contents/Info.plist"
}
if [ -n "$TARGET_SELECTOR" ]; then
  for target_name in $TARGET_NAMES; do
    target_kext="out/target/$target_name/Raphaeli.kext"
    stage_kext "$target_kext" "$STAGE/target/$target_name/Raphaeli.kext"
  done
else
  stage_kext "$KEXT" "$STAGE/kext/Raphaeli.kext"
fi
cp out/usr/lib/*.dylib out/usr/lib/radeon_icd.x86_64.json "$STAGE/usr/lib/" 2>/dev/null || \
cp out/usr/lib/*.dylib "$STAGE/usr/lib/"
cp firmware/amdgpu/*.bin "$STAGE/firmware/amdgpu/"
cp scripts/install.sh scripts/recovery-install.sh scripts/collect-recovery.sh scripts/oc-stage-graphics.py scripts/oc-install.py scripts/oc-install.sh "$STAGE/tools/"
cp Raphaeli/Firmware/stage.sh Raphaeli/Firmware/README.md "$STAGE/tools/fw/"
cp README.md "$STAGE/"

cat > "$STAGE/INSTALL.md" <<'EOF'
# Raphaeli install (AMD Radeon 780M / gfx1103, PCI 0x15bf)

Unsigned kext - requires AMFI + Secure Boot disabled (Hackintosh).

## OpenCore (recommended, black-screen-safe)
Select the kext matching the target OS explicitly:
1. `python3 tools/oc-install.py /path/to/EFI --add --target sequoia` (macOS 15)
   or `python3 tools/oc-install.py /path/to/EFI --add --target tahoe` (macOS 26)
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
1. `sudo ./tools/install.sh target/Sequoia/Raphaeli.kext`        # select the matching target bundle
2. `sudo ./tools/install.sh --apply`                   # adds raphaeli-amd=1
- target/Sequoia/ or target/Tahoe/ is selected explicitly; firmware blobs are shared

## Userspace (Vulkan)
- `usr/lib/libvulkan_radeon.dylib` + `usr/lib/radeon_icd.x86_64.json`
- point VK_ICD_FILENAMES at the json; libdrm libs are its dependencies

## Installing from macOS Recovery
For when the normal volume's WindowServer crashes and kextload is impossible.
Boot into RecoveryOS, open Terminal:
1. `./tools/recovery-install.sh /Volumes/Macintosh\ HD --apply`
   (auto-detects the volume if unambiguous; add `--dry-run` to preview;
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
  `sudo ./tools/install.sh target/Sequoia/Raphaeli.kext --apply` (or the Tahoe bundle)
  from the booted system
- Vulkan loader hint if discovery fails: `VK_DRIVER_FILES=/usr/local/share/vulkan/icd.d/radeon_icd.x86_64.json`
EOF

( cd dist && rm -f "$NAME.zip" && zip -qr "$NAME.zip" "$NAME" )
echo "dist/$NAME.zip:"; ls -la "dist/$NAME.zip"

# native installer (userspace + firmware only - the zip covers the kext route)
# lands in dist/, never inside the zip
./scripts/make-pkg.sh dist
