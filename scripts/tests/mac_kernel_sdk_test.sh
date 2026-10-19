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
grep -Fq 'KERNEL_SDK_COMMIT=3f750085caa17ec3a7880f11c11bf4f48cd6a164' "$ROOT/scripts/kernel-sdk.sh" && ok 'SDK commit pin declared' || bad 'SDK commit pin declared'
grep -Fq 'refusing active SDK fallback' "$ROOT/scripts/kernel-sdk.sh" && ok 'SDK fallback is fail-closed' || bad 'SDK fallback is fail-closed'
grep -Fq 'Library/x86_64' "$ROOT/scripts/kernel-sdk.sh" && ok 'pinned x86_64 kmod library selected' || bad 'pinned x86_64 kmod library selected'
grep -Fq 'KERNEL_SDK_LINK' "$ROOT/scripts/link.sh" && ok 'link uses pinned kmod library paths' || bad 'link uses pinned kmod library paths'
PINNED=3f750085caa17ec3a7880f11c11bf4f48cd6a164
DEFAULT=$(GPU_SRC_ROOT="$ROOT" bash -c '. "$1/scripts/kernel-sdk.sh"; printf "%s" "$KERNEL_SDK_ROOT"' _ "$ROOT")
[ "$(git -C "$DEFAULT" rev-parse HEAD 2>/dev/null)" = "$PINNED" ] && ok 'default SDK revision is pinned' || bad 'default SDK revision is pinned'
FAKE_SDK=$(mktemp -d "${TMPDIR:-/tmp}/raphaeli-sdk.XXXXXX")
trap 'rm -rf "$FAKE_SDK"' EXIT
mkdir -p "$FAKE_SDK/Headers" "$FAKE_SDK/Library/x86_64" "$FAKE_SDK/Library/universal"
if MAC_KERNEL_SDK="$FAKE_SDK" GPU_SRC_ROOT="$ROOT" bash -c '. "$1/scripts/kernel-sdk.sh"' _ "$ROOT" >/dev/null 2>&1; then
  bad 'uncommitted SDK override rejected'
else
  ok 'uncommitted SDK override rejected'
fi
if MAC_KERNEL_SDK="$ROOT/does-not-exist" GPU_SRC_ROOT="$ROOT" bash -c '. "$1/scripts/kernel-sdk.sh"' _ "$ROOT" >/dev/null 2>&1; then
  bad 'missing SDK rejected without fallback'
else
  ok 'missing SDK rejected without fallback'
fi
FAKE_VALID=$(mktemp -d "${TMPDIR:-/tmp}/raphaeli-sdk-valid.XXXXXX")
git clone -q "$ROOT/research/MacKernelSDK" "$FAKE_VALID"
selected=$(MAC_KERNEL_SDK="$FAKE_VALID" GPU_SRC_ROOT="$ROOT" bash -c '. "$1/scripts/kernel-sdk.sh"; printf "%s|%s|%s" "$KERNEL_SDK_HEADERS" "$KERNEL_SDK_KMOD_LIB" "$KERNEL_SDK_KMOD_CPP_LIB"' _ "$ROOT")
expected="$FAKE_VALID/Headers|$FAKE_VALID/Library/x86_64|$FAKE_VALID/Library/universal"
[ "$selected" = "$expected" ] && ok 'pinned SDK override values selected at runtime' || bad 'pinned SDK override values selected at runtime'
rm -rf "$FAKE_VALID"
[ -d "$ROOT/research/MacKernelSDK/Headers" ] && ok 'Sequoia MacKernelSDK source present' || bad 'Sequoia MacKernelSDK source present'
[ -f "$ROOT/Raphaeli/Kernel/Accel/upstream/SOURCE.lock" ] && ok 'tracked accelerator source lock present' || bad 'tracked accelerator source lock present'
python3 "$ROOT/scripts/prepare-accel-sources.py" --target sequoia --check-only >/dev/null && ok 'tracked accelerator source hashes validate' || bad 'tracked accelerator source hashes validate'
grep -R -Fq --exclude='mac_kernel_sdk_test.sh' 'research/tahoe-forwarding' "$ROOT/scripts" "$ROOT/Raphaeli" && bad 'ignored Tahoe forwarding header is not an input' || ok 'ignored Tahoe forwarding header is not an input'
exit "$fail"
