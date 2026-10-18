#!/bin/bash
# recovery-install.sh: Raphaeli installer for macOS RecoveryOS shell.
#
# Run from Recovery (root, no GUI, kextload not possible, WindowServer on the
# normal volume may be crashing). Differences from install.sh (direct route):
#   - target volume is NOT /: it lives under /Volumes/<name>; this script
#     auto-detects the single macOS volume or requires an explicit one
#   - APFS: tries `mount -uw <vol>` (ignored if already rw)
#   - Sealed System Volume: /usr/lib on the system snapshot is unwritable, so
#     dylibs go to <vol>/Library/Raphaeli/usr/lib/ and the Vulkan ICD json is
#     written to <vol>/usr/local/share/vulkan/icd.d/radeon_icd.x86_64.json
#     (usr/local is on the Data volume, writable; the Vulkan loader default-
#     scans it) with an ABSOLUTE library_path into /Library/Raphaeli/usr/lib/
#   - OC-injected setups (EFI/OC/config.plist present on the volume): kext
#     copy and auxKC are skipped - OC injects the kext; only firmware,
#     userspace and boot-args are touched. config.plist is never edited here;
#     use oc-install.py from the booted system.
#   - boot-args (nvram) are only modified with --apply; --uninstall removes
#     raphaeli-amd=1 and the raphaeli-gpu-attaching boot-guard marker
#
# Usage:
#   recovery-install.sh [/Volumes/Macintosh\ HD] [--target sequoia|tahoe] [--apply] [--dry-run]
#   recovery-install.sh /Volumes/Macintosh\ HD --uninstall
#   RAPHAELI_KEXT=/path/to/Raphaeli.kext recovery-install.sh /Volumes/Macintosh\ HD
#
# Boot guard (Raphaeli/Kernel/nmx_kext.cpp): between attach start and hand-over
# the kext sets the NVRAM marker raphaeli-gpu-attaching; if the marker is still
# set at the next boot the driver parks itself and the GPU stays with macOS.
# Clear it with: nvram -d raphaeli-gpu-attaching
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# dist zip layout: tools/recovery-install.sh next to target/, usr/lib/, firmware/
# dev tree fallback: out/target/<OS>/Raphaeli.kext + out/usr/lib + firmware/amdgpu
SRC_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
if [[ -d $SRC_ROOT/target ]]; then
  # Presence of target/ identifies a package even when a required tools/fw
  # input is missing; do not silently fall back to the checkout's stage.sh.
  PACKAGED=1
  FW_STAGE_SH=$SCRIPT_DIR/fw/stage.sh
else
  PACKAGED=0
  FW_STAGE_SH=$SRC_ROOT/Raphaeli/Firmware/stage.sh
fi
KEXT_SRC=${RAPHAELI_KEXT:-}
USR_LIB_SRC=$SRC_ROOT/usr/lib
[[ -d $USR_LIB_SRC ]] || USR_LIB_SRC=$SRC_ROOT/out/usr/lib
FW_SRC=${RAPHAELI_FW_SRC:-$SRC_ROOT/firmware/amdgpu}

KEXT_ID="me.tretrauit.raphaeli"
BOOT_ARG="raphaeli-amd=1"
NVRAM_GUARD="raphaeli-gpu-attaching"
ICD_DEST_REL="usr/local/share/vulkan/icd.d/radeon_icd.x86_64.json"
ICD_LIBRARY_PATH="/Library/Raphaeli/usr/lib/libvulkan_radeon.dylib"

# fw/README.md + fw/stage.sh: exactly the names amdgpu passes to request_firmware()
REQUIRED_FW=(
  gc_11_0_1_pfp.bin
  gc_11_0_1_me.bin
  gc_11_0_1_rlc.bin
  gc_11_0_1_mec.bin
  gc_11_0_1_imu.bin
  gc_11_0_1_mes1.bin
  sdma_6_0_2.bin
  psp_13_0_11_toc.bin
  psp_13_0_11_ta.bin
  vcn_4_0_2.bin
  dcn_3_1_4_dmcub.bin
)

DRY_RUN=0
APPLY=0
UNINSTALL=0
VOL=""
TARGET_SELECTOR=""

usage() {
  echo "usage: recovery-install.sh /Volumes/Macintosh\\ HD [--target sequoia|tahoe] [--apply] [--uninstall] [--dry-run]"
}

die() { echo "recovery-install.sh: $*" >&2; exit 1; }
log() { echo "== $*"; }

# Privileged step runner: prints the command in dry-run mode instead of running it.
run() {
  if (( DRY_RUN )); then
    printf 'DRY-RUN:'
    printf ' %q' "$@"
    echo
  else
    "$@"
  fi
}

# ---- argument parsing -------------------------------------------------------

while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --apply) APPLY=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --target)
      shift
      [[ $# -gt 0 ]] || die "--target requires sequoia or tahoe"
      [[ -z $TARGET_SELECTOR ]] || die "--target specified more than once"
      TARGET_SELECTOR=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
      case "$TARGET_SELECTOR" in
        sequoia|tahoe) ;;
        *) die "unsupported target '$1' (use sequoia or tahoe)" ;;
      esac
      ;;
    --target=*)
      [[ -z $TARGET_SELECTOR ]] || die "--target specified more than once"
      TARGET_SELECTOR=$(printf '%s' "${1#--target=}" | tr '[:upper:]' '[:lower:]')
      case "$TARGET_SELECTOR" in
        sequoia|tahoe) ;;
        *) die "unsupported target '${1#--target=}' (use sequoia or tahoe)" ;;
      esac
      ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1"; usage >&2 ;;
    *)
      [[ -z $VOL ]] || die "only one volume path may be given"
      VOL=$1
      ;;
  esac
  shift
done

# Resolve the selected bundle after parsing so --target may appear anywhere.
# RAPHAELI_KEXT is an explicit override and always takes precedence.
if [[ -z $KEXT_SRC ]]; then
  if [[ -n $TARGET_SELECTOR ]]; then
    KEXT_SRC=$SRC_ROOT/target/$([[ $TARGET_SELECTOR == sequoia ]] && echo Sequoia || echo Tahoe)/Raphaeli.kext
    if [[ ! -d $KEXT_SRC && $PACKAGED -eq 0 ]]; then
      KEXT_SRC=$SRC_ROOT/out/target/$([[ $TARGET_SELECTOR == sequoia ]] && echo Sequoia || echo Tahoe)/Raphaeli.kext
      [[ -d $KEXT_SRC ]] || KEXT_SRC=$SRC_ROOT/out/Raphaeli.kext
    fi
  elif [[ $PACKAGED -eq 0 ]]; then
    KEXT_SRC=$SRC_ROOT/kext/Raphaeli.kext
    [[ -d $KEXT_SRC ]] || KEXT_SRC=$SRC_ROOT/out/Raphaeli.kext
  else
    die "packaged installs require --target sequoia or --target tahoe"
  fi
fi

# ---- volume resolution ------------------------------------------------------

# The RecoveryOS root is a ramdisk; the macOS volume(s) appear under /Volumes.
# RAPHAELI_VOLUMES_DIR overrides the mount root (test hook).
resolve_volume() {
  if [[ -n $VOL ]]; then
    [[ -d $VOL ]] || die "no such volume: $VOL"
    [[ -d $VOL/Library ]] || die "$VOL does not look like a macOS volume (no Library/)"
    return
  fi
  local volsdir=${RAPHAELI_VOLUMES_DIR:-/Volumes}
  local pref=() other=() d
  for d in "$volsdir"/*; do
    [[ -d $d ]] || continue
    if [[ -d $d/Library/Extensions ]]; then
      pref+=("$d")
    elif [[ -d $d/Library ]]; then
      other+=("$d")
    fi
  done
  if ((${#pref[@]} == 1)); then
    VOL=${pref[0]}
  elif ((${#pref[@]} == 0 && ${#other[@]} == 1)); then
    VOL=${other[0]}
  else
    echo "candidates under $volsdir:" >&2
    ((${#pref[@]})) && printf '  %s (has Library/Extensions)\n' "${pref[@]}" >&2
    ((${#other[@]})) && printf '  %s\n' "${other[@]}" >&2
    usage >&2
    die "could not pick a unique target volume; pass it explicitly"
  fi
}

resolve_volume
log "target volume: $VOL"

# ---- uninstall --------------------------------------------------------------

if (( UNINSTALL )); then
  log "uninstalling Raphaeli from $VOL (kext, firmware, userspace, boot-arg)"
  run rm -rf "$VOL/Library/Extensions/Raphaeli.kext"
  run rm -rf "$VOL/Library/Raphaeli"
  run rm -f "$VOL/$ICD_DEST_REL"
  run rm -f "$VOL/Library/KernelCollections/Raphaeli.auxkc"
  current=$(nvram -p 2>/dev/null | awk '$1=="boot-args"{$1="";sub(/^[ \t]+/,"");print}' || true)
  if [[ -n $current ]]; then
    rest=$(echo "$current" | tr ' ' '\n' | grep -vx "$BOOT_ARG" | tr '\n' ' ' | sed 's/ $//') || true
    if [[ -n $rest ]]; then
      run nvram boot-args="$rest"
    else
      run nvram -d boot-args
    fi
  fi
  run nvram -d "$NVRAM_GUARD"
  log "done. If the kext was OC-injected, disable it with oc-install.py --disable."
  exit 0
fi

# ---- source tree validation --------------------------------------------------

log "dist source root: $SRC_ROOT"
[[ -d $KEXT_SRC/Contents ]] || die "not a kext bundle: $KEXT_SRC"
plutil -lint "$KEXT_SRC/Contents/Info.plist" >/dev/null || die "Info.plist does not lint: $KEXT_SRC"
bundle_id=$(plutil -extract CFBundleIdentifier raw "$KEXT_SRC/Contents/Info.plist")
[[ $bundle_id == "$KEXT_ID" ]] || die "unexpected bundle id '$bundle_id' (expected $KEXT_ID)"
for userspace_file in libdrm.2.dylib libdrm_amdgpu.1.dylib libvulkan_radeon.dylib; do
  [[ -f $USR_LIB_SRC/$userspace_file ]] || die "missing $USR_LIB_SRC/$userspace_file (dist zip usr/lib/)"
done

log "selected kext: $KEXT_SRC${TARGET_SELECTOR:+ (target $TARGET_SELECTOR)}"
log "firmware census in $FW_SRC (required: ${#REQUIRED_FW[@]})"
missing=()
for f in "${REQUIRED_FW[@]}"; do
  [[ -f $FW_SRC/$f ]] || missing+=("$f")
done
if ((${#missing[@]})); then
  echo "MISSING REQUIRED firmware blobs:" >&2
  for f in "${missing[@]}"; do echo "  amdgpu/$f" >&2; done
  die "the dist zip should contain firmware/amdgpu/*.bin"
fi

# Optional integrity check: verify against a SHA256SUMS manifest if the
# package provides one (firmware/amdgpu/SHA256SUMS), skip otherwise.
if [[ -f $FW_SRC/SHA256SUMS ]]; then
  log "verifying firmware checksums (SHA256SUMS)"
  ( cd "$FW_SRC" && shasum -a 256 -c SHA256SUMS --status ) || die "firmware checksum verification FAILED (SHA256SUMS)"
else
  log "no SHA256SUMS manifest next to firmware; skipping checksum verification"
fi

# ---- APFS: make the Data volume writable ------------------------------------

if (( ! DRY_RUN )); then
  mount -uw "$VOL" 2>/dev/null || true   # ignored if already rw (or read-only snapshot)
else
  echo "DRY-RUN: mount -uw $VOL"
fi

# ---- userspace: dylibs to Library/Raphaeli (NOT /usr/lib: sealed snapshot) ---

LIB_DEST=$VOL/Library/Raphaeli/usr/lib
log "installing dylibs -> $LIB_DEST"
run mkdir -p "$LIB_DEST"
run cp -f "$USR_LIB_SRC"/*.dylib "$LIB_DEST"/

# Vulkan ICD json: absolute library_path, loader default-scans
# /usr/local/share/vulkan/icd.d (on the Data volume, writable).
ICD_DEST=$VOL/$ICD_DEST_REL
log "writing Vulkan ICD json -> $ICD_DEST"
run mkdir -p "$(dirname "$ICD_DEST")"
icd_body=$'{\n  "file_format_version": "1.0.0",\n  "ICD": {\n    "library_path": "'"$ICD_LIBRARY_PATH"'",\n    "api_version": "1.3.0"\n  }\n}\n'
if (( DRY_RUN )); then
  echo "DRY-RUN: write $ICD_DEST (library_path=$ICD_LIBRARY_PATH)"
else
  printf '%s' "$icd_body" > "$ICD_DEST"
fi

# ---- firmware ----------------------------------------------------------------

FW_DEST=$VOL/Library/Raphaeli/firmware
log "staging firmware -> $FW_DEST (stage.sh)"
[[ -f $FW_STAGE_SH ]] || die "stage.sh not found at $FW_STAGE_SH"
run sh "$FW_STAGE_SH" "$FW_SRC" "$FW_DEST"

# ---- kext: OC-detect or direct copy + auxKC ----------------------------------

OC_MODE=0
if [[ -f $VOL/EFI/OC/config.plist ]]; then
  OC_MODE=1
  log "OC config found at $VOL/EFI/OC/config.plist: skipping kext copy + auxKC (OC injects)"
  echo "   NOTE: config.plist is not edited from Recovery. Enable/disable the kext"
  echo "   with oc-install.py on the booted system: python3 tools/oc-install.py <EFI> --enable|--disable"
else
  KEXT_DEST=$VOL/Library/Extensions/Raphaeli.kext
  log "installing kext -> $KEXT_DEST (root:wheel, 755)"
  run rm -rf "$KEXT_DEST"
  run ditto "$KEXT_SRC" "$KEXT_DEST"
  run chown -R root:wheel "$KEXT_DEST" || log "WARNING: chown failed (not root?); kext must be root:wheel to load"
  run chmod -R 755 "$KEXT_DEST"

  # auxKC: best effort. kmutil exists in recent RecoveryOS; needs a matching KDK
  # and the target volume's kernel collections.
  if [[ -d $VOL/System/Library/KernelCollections ]] && command -v kmutil >/dev/null 2>&1; then
    tgt_build=$(plutil -extract ProductBuildVersion raw "$VOL/System/Library/CoreServices/SystemVersion.plist" 2>/dev/null || true)
    tgt_ver=$(plutil -extract ProductVersion raw "$VOL/System/Library/CoreServices/SystemVersion.plist" 2>/dev/null || true)
    kdk=""
    for d in "$VOL/Library/Developer/KDKs"/KDK_*.kdk; do
      [[ -d $d ]] || continue
      [[ $d == *"_$tgt_build.kdk" || $d == *"_${tgt_ver}_"* ]] && kdk=$d
    done
    if [[ -n $kdk ]]; then
      log "building aux KC (kmutil, KDK: $(basename "$kdk"))"
      run mkdir -p "$VOL/Library/KernelCollections"
      run kmutil create \
        -a x86_64 -n aux -x \
        -p "$KEXT_DEST" \
        --no-authentication \
        -A "$VOL/Library/KernelCollections/Raphaeli.auxkc" \
        -B "$VOL/System/Library/KernelCollections/BootKernelExtensions.kc" \
        -S "$VOL/System/Library/KernelCollections/SystemKernelExtensions.kc" \
        --kdk "$kdk" || log "WARNING: kmutil create failed; build the auxKC from the booted system"
    else
      log "no matching KDK under $VOL/Library/Developer/KDKs (target build ${tgt_build:-?}); skipping auxKC"
    fi
  else
    log "kmutil or target kernel collections not available; skipping auxKC"
  fi
  echo "   If no auxKC was built here, finish from the booted system:"
  echo "     sudo ./tools/install.sh kext/Raphaeli.kext --apply"
  echo "   (or use OpenCore injection instead - see INSTALL.md)"
fi

# ---- boot-args (only with --apply) -------------------------------------------

if (( APPLY )); then
  current=$(nvram -p 2>/dev/null | awk '$1=="boot-args"{$1="";sub(/^[ \t]+/,"");print}' || true)
  if [[ " $current " == *" $BOOT_ARG "* ]]; then
    log "boot-args already contain $BOOT_ARG"
  else
    log "applying boot-arg opt-in ($BOOT_ARG)"
    run nvram boot-args="$(echo "$current $BOOT_ARG" | sed 's/^ //')"
  fi
  echo
  echo "Rollback / safety:"
  echo "  nvram -d $NVRAM_GUARD      # clear the boot-guard marker to retry an attach"
  echo "  nvram -d boot-args         # full reset (only if no other boot-args were set)"
else
  log "not applying boot-args (pass --apply to add $BOOT_ARG)"
fi

# ---- next steps ----------------------------------------------------------------

cat <<EOF

Userspace (Vulkan) notes:
  - dylibs: /Library/Raphaeli/usr/lib/ (NOT /usr/lib - Sealed System Volume)
  - ICD json: /usr/local/share/vulkan/icd.d/radeon_icd.x86_64.json
    (library_path is absolute into /Library/Raphaeli/usr/lib/)
  - If the loader does not pick it up, set VK_DRIVER_FILES=/usr/local/share/vulkan/icd.d/radeon_icd.x86_64.json

Reboot. Without $BOOT_ARG the kext stays inert (probe() declines every device).
EOF

log "done (dry-run: $DRY_RUN, oc-mode: $OC_MODE)"
