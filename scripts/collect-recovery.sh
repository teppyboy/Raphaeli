#!/bin/bash
# Run inside Recovery Terminal: collect-recovery.sh <new-output-dir> [mounted-EFI-root]
# Read-only sources; no mounts, NVRAM access, config copies, or system changes.
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "usage: $0 <new-output-dir> [mounted-EFI-root]" >&2
    exit 1
fi
OUT=$1
EFI=${2:-}
# Fixture override for host tests; normally collect the running Recovery root.
ROOT=${RAPHAELI_RECOVERY_ROOT:-/}
KC="$ROOT/System/Library/KernelCollections/BootKernelExtensions.kc"
VERSION="$ROOT/System/Library/CoreServices/SystemVersion.plist"
[ -f "$KC" ] && [ -f "$VERSION" ] || {
    echo "Missing Recovery Boot KC or SystemVersion.plist under $ROOT" >&2
    exit 1
}
if [ -n "$EFI" ] && [ ! -d "$EFI/EFI/OC" ]; then
    echo "Expected mounted EFI root containing EFI/OC: $EFI" >&2
    exit 1
fi
[ ! -e "$OUT.tar.gz" ] && [ ! -L "$OUT.tar.gz" ] || {
    echo "Archive already exists: $OUT.tar.gz" >&2
    exit 1
}
mkdir "$OUT" # Refuse existing output, including symlinks; never overwrite evidence.
OUT=$(cd "$OUT" && pwd)
cp "$KC" "$OUT/BootKernelExtensions.kc"
cp "$VERSION" "$OUT/SystemVersion.plist"
{
    echo 'Running OS:'
    sw_vers
    uname -a
    echo "Collected system root: $ROOT"
} > "$OUT/system.txt"

if [ -n "$EFI" ]; then
    mkdir "$OUT/opencore-logs"
    for dir in "$EFI" "$EFI/EFI/OC"; do
        for log in "$dir"/opencore-*.txt "$dir"/opencore-*.log; do
            [ -f "$log" ] || continue
            # Keep log locations separate to prevent duplicate basenames overwriting.
            if [ "$dir" = "$EFI" ]; then prefix=root; else prefix=OC; fi
            cp "$log" "$OUT/opencore-logs/$prefix-$(basename "$log")"
        done
    done
    KEXT="$EFI/EFI/OC/Kexts/Raphaeli.kext/Contents"
    if [ -f "$KEXT/Info.plist" ]; then
        cp "$KEXT/Info.plist" "$OUT/Raphaeli-Info.plist"
    fi
    if [ -f "$KEXT/MacOS/Raphaeli" ]; then
        shasum -a 256 "$KEXT/MacOS/Raphaeli" > "$OUT/EFI-kext-sha256.txt"
    fi
else
    echo 'No EFI supplied; OpenCore logs and EFI kext hash omitted.' >&2
fi
(
    cd "$OUT"
    find . -type f ! -name SHA256SUMS -exec shasum -a 256 {} \; > SHA256SUMS
)
# Refuse an archive created by another process since the initial check.
(set -C; tar -czf - -C "$(dirname "$OUT")" "$(basename "$OUT")" > "$OUT.tar.gz")
printf 'Collected: %s.tar.gz\nReview logs for serial numbers/UUIDs before sharing.\n' "$OUT"
