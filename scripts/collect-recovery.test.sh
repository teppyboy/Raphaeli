#!/bin/bash
# Host-only fixtures; never mount or change system/EFI state.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ROOT="$WORK/Recovery root"
EFI="$WORK/EFI volume"
mkdir -p "$ROOT/System/Library/KernelCollections" "$ROOT/System/Library/CoreServices" \
    "$EFI/EFI/OC/Kexts/Raphaeli.kext/Contents/MacOS"
printf 'test KC\n' > "$ROOT/System/Library/KernelCollections/BootKernelExtensions.kc"
printf 'test version\n' > "$ROOT/System/Library/CoreServices/SystemVersion.plist"
printf 'root log\n' > "$EFI/opencore-test.txt"
printf 'OC log\n' > "$EFI/EFI/OC/opencore-test.txt"
printf 'test kext\n' > "$EFI/EFI/OC/Kexts/Raphaeli.kext/Contents/MacOS/Raphaeli"
printf 'test plist\n' > "$EFI/EFI/OC/Kexts/Raphaeli.kext/Contents/Info.plist"
export RAPHAELI_RECOVERY_ROOT="$ROOT"
/bin/bash "$HERE/collect-recovery.sh" "$WORK/diagnostic bundle" "$EFI"
mkdir "$WORK/unpacked"
tar -xzf "$WORK/diagnostic bundle.tar.gz" -C "$WORK/unpacked"
BUNDLE="$WORK/unpacked/diagnostic bundle"
cmp "$BUNDLE/BootKernelExtensions.kc" "$ROOT/System/Library/KernelCollections/BootKernelExtensions.kc"
cmp "$BUNDLE/SystemVersion.plist" "$ROOT/System/Library/CoreServices/SystemVersion.plist"
cmp "$BUNDLE/opencore-logs/root-opencore-test.txt" "$EFI/opencore-test.txt"
cmp "$BUNDLE/opencore-logs/OC-opencore-test.txt" "$EFI/EFI/OC/opencore-test.txt"
(cd "$BUNDLE" && shasum -a 256 -c SHA256SUMS)
(cd / && shasum -a 256 -c "$BUNDLE/EFI-kext-sha256.txt")
[ ! -e "$BUNDLE/config.plist" ]
if /bin/bash "$HERE/collect-recovery.sh" "$WORK/diagnostic bundle" "$EFI"; then
    echo 'FAIL: overwrote existing evidence' >&2; exit 1
fi
if /bin/bash "$HERE/collect-recovery.sh" "$WORK/bad EFI" "$WORK/missing EFI"; then
    echo 'FAIL: accepted invalid EFI' >&2; exit 1
fi
/bin/bash "$HERE/collect-recovery.sh" "$WORK/no EFI"
[ -f "$WORK/no EFI.tar.gz" ]
[ ! -e "$WORK/no EFI/EFI-kext-sha256.txt" ]
rm "$ROOT/System/Library/KernelCollections/BootKernelExtensions.kc"
if /bin/bash "$HERE/collect-recovery.sh" "$WORK/missing KC"; then
    echo 'FAIL: accepted missing KC' >&2; exit 1
fi
[ ! -e "$WORK/missing KC" ]
echo 'PASS: Recovery collector, spaced paths, archive integrity, duplicate log names, overwrite refusal, optional/invalid EFI, missing KC'
