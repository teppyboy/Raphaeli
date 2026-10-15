#!/bin/bash
# Raphaeli install/deploy for the Radeon 780M target machine (Phoenix, 0x15bf, gfx1103).
#
# Installs xkpi/out/Raphaeli.kext into /Library/Extensions, stages AMD firmware
# into /Library/Raphaeli/firmware (layout expected by xnu/nmx_platform.cpp),
# builds an auxiliary kext collection offline via kmutil(8), and (opt-in)
# sets the raphaeli-amd=1 boot-arg.
#
# Facts this script relies on (proven on the dev host, macOS 15.7.8 / 24G824):
#   - kext bundles must be root:wheel or kmutil treats them as codeless
#   - aux KC recipe: kmutil create -a x86_64 -n aux -x -p <root-owned kext>
#     --no-authentication -A <out> -B <boot kc> -S <sys kc> --kdk <matching KDK>
#   - SIP is Custom Configuration (Kext Signing + Filesystem Protections off),
#     AMFI off, so no code signature is required
#   - kmutil install only updates the Boot/System collections; it does NOT
#     apply an offline-built aux KC. The aux KC the system loads lives in
#     /Library/KernelCollections (AuxiliaryKernelExtensions.kc), so the apply
#     step is copying the built artifact there (kernelmanagerd's own rebuild
#     path is `kmutil rebuild`, which prompts for approval).
#
# Usage:
#   install.sh [--dry-run] [--apply] [kext-path]   # default kext: out/Raphaeli.kext
#   install.sh [--dry-run] --uninstall
#
# Boot guard (xnu/nmx_kext.cpp): between attach start and hand-over the kext
# sets the NVRAM marker raphaeli-gpu-attaching; if the marker is still set at
# the next boot the driver parks itself and the GPU stays with macOS. Clear it
# with: nvram -d raphaeli-gpu-attaching
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)   # Raphaeli/ project root (contains xkpi/ and firmware/)

KEXT_ID="me.tretrauit.raphaeli"
DEST_KEXT="/Library/Extensions/Raphaeli.kext"
FW_ROOT="/Library/Raphaeli/firmware"
FW_SRC="${RAPHAELI_FW_SRC:-$REPO_DIR/firmware/amdgpu}"
FW_STAGE_SH="$SCRIPT_DIR/fw/stage.sh"
AUXKC_OUT="/Library/KernelCollections/Raphaeli.auxkc"
KDK_DIR="/Library/Developer/KDKs"
BOOT_ARG="raphaeli-amd=1"
NVRAM_GUARD="raphaeli-gpu-attaching"

# fw/README.md + fw/stage.sh: exactly the names amdgpu passes to request_firmware()
REQUIRED_FW=(
  ip_discovery.bin
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
KEXT_SRC=""

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

die() { echo "install.sh: $*" >&2; exit 1; }
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

sudocmd() {
  if (( EUID == 0 )); then
    run "$@"
  elif (( DRY_RUN )); then
    printf 'DRY-RUN: sudo'
    printf ' %q' "$@"
    echo
  else
    sudo "$@"
  fi
}

# ---- argument parsing -------------------------------------------------------

while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --apply) APPLY=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *)
      [[ -z $KEXT_SRC ]] || die "only one kext path may be given"
      KEXT_SRC=$1
      ;;
  esac
  shift
done

if (( UNINSTALL )); then
  log "uninstalling Raphaeli (kext, firmware, aux KC artifact, boot-arg)"
  sudocmd rm -rf "$DEST_KEXT"
  sudocmd rm -rf "$FW_ROOT"
  sudocmd rm -f "$AUXKC_OUT"
  current=$(nvram -p 2>/dev/null | awk '$1=="boot-args"{$1="";sub(/^[ \t]+/,"");print}' || true)
  if [[ -n $current ]]; then
    rest=$(echo "$current" | tr ' ' '\n' | grep -vx "$BOOT_ARG" | tr '\n' ' ' | sed 's/ $//')
    if [[ -n $rest ]]; then
      sudocmd nvram boot-args="$rest"
    else
      sudocmd nvram -d boot-args
    fi
  fi
  sudocmd nvram -d "$NVRAM_GUARD"
  echo
  echo "The kext stays linked in the auxiliary kext collection until kernelmanagerd rebuilds it."
  echo "Finish with:  sudo kmutil rebuild   (confirm the removal, then reboot)"
  echo "Rollback of the boot guard at any time:  nvram -d $NVRAM_GUARD"
  exit 0
fi

# ---- (1) validate the kext bundle ------------------------------------------

KEXT_SRC=${KEXT_SRC:-$SCRIPT_DIR/out/Raphaeli.kext}
log "validating kext bundle: $KEXT_SRC"
[[ -d $KEXT_SRC/Contents ]] || die "not a kext bundle: $KEXT_SRC"
plutil -lint "$KEXT_SRC/Contents/Info.plist" >/dev/null || die "Info.plist does not lint"
bundle_id=$(plutil -extract CFBundleIdentifier raw "$KEXT_SRC/Contents/Info.plist")
[[ $bundle_id == "$KEXT_ID" ]] || die "unexpected bundle id '$bundle_id' (expected $KEXT_ID)"
exe=$(plutil -extract CFBundleExecutable raw "$KEXT_SRC/Contents/Info.plist")
bin="$KEXT_SRC/Contents/MacOS/$exe"
[[ -f $bin ]] || die "missing executable: $bin"
otool -l "$bin" | grep -q LC_UUID || die "no LC_UUID in $bin (not a linked kernel binary)"
strings "$bin" | grep -qx "$KEXT_ID" || die "kmod_info name '$KEXT_ID' not found in $bin"
log "kext bundle OK ($bundle_id, $(du -h "$bin" | cut -f1))"

# ---- (3) firmware census (before touching the system) ----------------------

log "firmware census in $FW_SRC (required: ${#REQUIRED_FW[@]})"
missing=()
for f in "${REQUIRED_FW[@]}"; do
  [[ -f $FW_SRC/$f ]] || missing+=("$f")
done
if ((${#missing[@]})); then
  echo "MISSING REQUIRED firmware blobs:" >&2
  for f in "${missing[@]}"; do echo "  amdgpu/$f" >&2; done
  echo "Fetch them from the linux-firmware repository (amdgpu/ directory)," >&2
  echo "  https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/" >&2
  echo "and place them in $FW_SRC/, then re-run." >&2
  exit 1
fi
log "census ${#REQUIRED_FW[@]}/${#REQUIRED_FW[@]} required blobs present"

# ---- (4) matching KDK autodetect -------------------------------------------

pver=$(sw_vers -productVersion)
bver=$(sw_vers -buildVersion)
kdk="$KDK_DIR/KDK_${pver}_${bver}.kdk"
if [[ ! -d $kdk ]]; then
  echo "no matching KDK for macOS ${pver} (${bver}); found:" >&2
  ls "$KDK_DIR" 2>/dev/null || echo "  (none in $KDK_DIR)" >&2
  die "install KDK_${pver}_${bver}.kdk before building the aux KC"
fi
log "KDK: $kdk"

# ---- (2) install the kext ---------------------------------------------------

log "installing kext to $DEST_KEXT (root:wheel, required by kmutil)"
sudocmd rm -rf "$DEST_KEXT"
sudocmd ditto "$KEXT_SRC" "$DEST_KEXT"
sudocmd chown -R root:wheel "$DEST_KEXT"

# ---- (3) stage firmware ------------------------------------------------------

log "staging firmware into $FW_ROOT"
sudocmd mkdir -p "$FW_ROOT"
sudocmd chown root:wheel "$FW_ROOT"
sudocmd sh "$FW_STAGE_SH" "$FW_SRC" "$FW_ROOT"

# ---- (4) build the aux KC offline -------------------------------------------

log "building aux KC -> $AUXKC_OUT"
sudocmd mkdir -p "$(dirname "$AUXKC_OUT")"
sudocmd kmutil create \
  -a x86_64 -n aux -x \
  -p "$DEST_KEXT" \
  --no-authentication \
  -A "$AUXKC_OUT" \
  -B /System/Library/KernelCollections/BootKernelExtensions.kc \
  -S /System/Library/KernelCollections/SystemKernelExtensions.kc \
  --kdk "$kdk"

# ---- next steps (printed, not run; this host has no 780M) -------------------

live_kc=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
[[ -f $live_kc ]] || live_kc=/Library/KernelCollections/BootKernelExtensions.kc
cat <<EOF

Next steps (run these on the 780M target machine, not here):

  1. Apply the offline-built aux KC. Per kmutil(8), 'kmutil install' only
     rebuilds the Boot/System collections and 'kmutil create' only builds;
     an offline-built aux KC is applied by placing it where kernelmanagerd
     loads it from:

       sudo cp $live_kc ${live_kc}.pre-raphaeli   # keep a rollback copy
       sudo cp $AUXKC_OUT $live_kc

     (Managed alternative: 'sudo kmutil rebuild' lets kernelmanagerd rebuild
     the aux KC from /Library/Extensions itself, with an approval prompt.)

  2. Opt in to GPU attachment (see --apply):
       sudo nvram boot-args="\$(nvram -p | awk '\$1=="boot-args"{\$1="";sub(/^[ \\t]+/,"");print}') $BOOT_ARG"
     ...or just re-run this script with --apply.

  3. Reboot. The kext only matches after opting in; probe() declines every
     device without $BOOT_ARG (or the "raphaeli-gpu" device property).

Safety / rollback:
  - Boot guard ($NVRAM_GUARD): the kext sets this NVRAM marker while
    attaching; if an attach never returns, the next boot parks the driver
    and the GPU stays with macOS. Clear it to retry:
      nvram -d $NVRAM_GUARD
  - Disable the driver: remove $BOOT_ARG from boot-args, delete $DEST_KEXT,
    restore the saved aux KC, then 'sudo kmutil rebuild' and reboot.
  - Last resort (Recovery Mode): kmutil trigger-panic-medic removes the aux
    KC and all kext approvals.

EOF

# ---- (5) --apply: opt-in boot-arg -------------------------------------------

if (( APPLY )); then
  log "applying boot-arg opt-in ($BOOT_ARG)"
  current=$(nvram -p 2>/dev/null | awk '$1=="boot-args"{$1="";sub(/^[ \t]+/,"");print}' || true)
  if [[ $current == *"$BOOT_ARG"* ]]; then
    log "boot-args already contain $BOOT_ARG"
  else
    sudocmd nvram boot-args="$current $BOOT_ARG"
  fi
  cat <<EOF
Boot-arg applied. Rollback / safety:
  nvram -d $NVRAM_GUARD          # clear the boot-guard marker to retry an attach
  nvram -d boot-args             # full reset (only if no other boot-args were set)
If the Mac fails to boot with GPU output, the driver parks itself after the
guard marker persists; recovery needs another display or SSH.
EOF
else
  log "not applying boot-args (pass --apply to add $BOOT_ARG)"
fi

log "done (dry-run: $DRY_RUN)"
