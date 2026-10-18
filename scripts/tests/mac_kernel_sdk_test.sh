#!/bin/bash
# Static checks for pinned MacKernelSDK selection in kernel build wrappers.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=$((fail + 1)); }
for script in ccxx.sh cc.sh cclk.sh ccsrc.sh cc-i915.sh cc-xe.sh; do
  grep -Fq 'kernel-sdk.sh' "$ROOT/scripts/$script" && ok "$script selects kernel SDK" || bad "$script selects kernel SDK"
  grep -Fq 'KERNEL_SDK_INCLUDE' "$ROOT/scripts/$script" && ok "$script uses SDK headers" || bad "$script uses SDK headers"
done
for script in kext-build.sh link.sh; do
  grep -Fq 'kernel-sdk.sh' "$ROOT/scripts/$script" && ok "$script selects kernel SDK" || bad "$script selects kernel SDK"
  grep -Fq 'KERNEL_SDK_LINK' "$ROOT/scripts/$script" && ok "$script links with selected SDK" || bad "$script links with selected SDK"
done
grep -Fq 'MAC_KERNEL_SDK' "$ROOT/scripts/kernel-sdk.sh" && ok 'MAC_KERNEL_SDK override documented' || bad 'MAC_KERNEL_SDK override documented'
grep -Fq 'WARNING: MacKernelSDK absent' "$ROOT/scripts/kernel-sdk.sh" && ok 'SDK fallback warns explicitly' || bad 'SDK fallback warns explicitly'
grep -Fq 'Library/x86_64' "$ROOT/scripts/kernel-sdk.sh" && ok 'pinned x86_64 kmod library selected' || bad 'pinned x86_64 kmod library selected'
grep -Fq 'KERNEL_SDK_LINK' "$ROOT/scripts/link.sh" && ok 'link uses pinned kmod library paths' || bad 'link uses pinned kmod library paths'
FAKE_SDK=$(mktemp -d "${TMPDIR:-/tmp}/raphaeli-sdk.XXXXXX")
trap 'rm -rf "$FAKE_SDK"' EXIT
mkdir -p "$FAKE_SDK/Headers" "$FAKE_SDK/Library/x86_64" "$FAKE_SDK/Library/universal"
selected=$(MAC_KERNEL_SDK="$FAKE_SDK" GPU_SRC_ROOT="$ROOT" bash -c '. "$1/scripts/kernel-sdk.sh"; printf "%s|%s|%s" "$KERNEL_SDK_HEADERS" "$KERNEL_SDK_KMOD_LIB" "$KERNEL_SDK_KMOD_CPP_LIB"' _ "$ROOT")
expected="$FAKE_SDK/Headers|$FAKE_SDK/Library/x86_64|$FAKE_SDK/Library/universal"
[ "$selected" = "$expected" ] && ok 'SDK override values are selected at runtime' || bad 'SDK override values are selected at runtime'
[ -d "$ROOT/research/MacKernelSDK/Headers" ] && ok 'Sequoia MacKernelSDK source present' || bad 'Sequoia MacKernelSDK source present'
for header in \
  IOAccelerator.h IOGraphicsAccelerator2.h \
  IOAccelEventMachineFast2.h IOAccelLegacyDisplayMachine.h \
  IOAccelTask.h IOAccelMemoryMap.h IOAccelResource2.h \
  IOAccelSysMemory.h IOAccelVidMemory.h IOAccelLegacySurface.h \
  IOAccelGLContext2.h IOAccel2DContext2.h IOAccelCLContext2.h \
  IOAccelVideoContext2.h; do
  case "$header" in
    IOAccelerator.h|IOGraphicsAccelerator2.h) subdir=re ;;
    *) subdir=iofam ;;
  esac
  path="$ROOT/research/nvidia-macos-driver/kexts/NVRM/accel/$subdir/$header"
  [ -f "$path" ] && ok "Sequoia accelerator source present: $header" || bad "Sequoia accelerator source present: $header"
done
[ ! -f "$ROOT/research/tahoe-forwarding/nmx_accel_tahoe_forwarding.h" ] && ok 'Tahoe forwarding header remains absent' || bad 'Tahoe forwarding header remains absent'
exit "$fail"
