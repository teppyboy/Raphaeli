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
grep -Fq 'MAC_KERNEL_SDK' "$ROOT/scripts/kernel-sdk.sh" && ok 'MAC_KERNEL_SDK override documented' || bad 'MAC_KERNEL_SDK override documented'
grep -Fq 'WARNING: MacKernelSDK absent' "$ROOT/scripts/kernel-sdk.sh" && ok 'SDK fallback warns explicitly' || bad 'SDK fallback warns explicitly'
grep -Fq 'Library/x86_64' "$ROOT/scripts/kernel-sdk.sh" && ok 'pinned x86_64 kmod library selected' || bad 'pinned x86_64 kmod library selected'
grep -Fq 'KERNEL_SDK_LINK' "$ROOT/scripts/link.sh" && ok 'link uses pinned kmod library paths' || bad 'link uses pinned kmod library paths'
[ -d "$ROOT/research/MacKernelSDK/Headers" ] && ok 'Sequoia MacKernelSDK source present' || bad 'Sequoia MacKernelSDK source present'
[ -f "$ROOT/research/nvidia-macos-driver/kexts/NVRM/accel/re/IOAccelerator.h" ] && ok 'Sequoia accelerator source present' || bad 'Sequoia accelerator source present'
[ ! -f "$ROOT/research/tahoe-forwarding/nmx_accel_tahoe_forwarding.h" ] && ok 'Tahoe forwarding header remains absent' || bad 'Tahoe forwarding header remains absent'
exit "$fail"
