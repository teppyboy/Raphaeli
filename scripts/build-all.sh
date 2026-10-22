#!/bin/bash
# build-all.sh [all|sequoia|tahoe]: build isolated per-target kext bundles from one source compile.
#   out/target/Sequoia/Raphaeli.kext  - Sequoia 15.7.8 (KDK 24G824) bundle
#   out/target/Tahoe/Raphaeli.kext    - Tahoe bundle, accepted only after the OpenCore injection gate
# Default is all. Every Tahoe input is checked before the 900-source build starts, and the
# Tahoe injection gate must pass or the script exits nonzero. Never writes out-disp/.
set -euo pipefail
X=$(cd "$(dirname "$0")/.." && pwd)
cd "$X"

TARGET=${1:-all}
case "$TARGET" in
    all|sequoia|tahoe) ;;
    *) echo "usage: $0 [all|sequoia|tahoe]" >&2; exit 2 ;;
esac

# Explicit inputs; nothing is searched for on the host.
FW_SOURCE=${RAPHAELI_FW_SRC:-}
[ -n "$FW_SOURCE" ] && [ -d "$FW_SOURCE" ] || {
    echo "build-all.sh: set RAPHAELI_FW_SRC to a linux-firmware/amdgpu directory" >&2; exit 1; }

# Tahoe gate inputs: the OpenCore KextInject tool, the exact Tahoe Recovery BootKernelExtensions.kc,
# and the matching-build KDK Extensions dir supplying IOGraphicsFamily and IOAcceleratorFamily2.
TAHOE_KC=${RAPHAELI_TAHOE_KC:-}
KEXTINJECT=${RAPHAELI_OC_KEXTINJECT:-}
KDK_EXT=${RAPHAELI_TAHOE_KDK_EXT:-}
if [ "$TARGET" != sequoia ]; then
    [ -x "$KEXTINJECT" ] || { echo "build-all.sh: set RAPHAELI_OC_KEXTINJECT to an executable OpenCore KextInject (Tahoe gate)" >&2; exit 1; }
    [ -f "$TAHOE_KC" ] || { echo "build-all.sh: set RAPHAELI_TAHOE_KC to the Tahoe Recovery BootKernelExtensions.kc" >&2; exit 1; }
    [ -d "$KDK_EXT" ] || { echo "build-all.sh: set RAPHAELI_TAHOE_KDK_EXT to the Tahoe KDK .../System/Library/Extensions dir" >&2; exit 1; }
    for dep in IOGraphicsFamily.kext/IOGraphicsFamily IOGraphicsFamily.kext/Info.plist \
               IOAcceleratorFamily2.kext/Contents/MacOS/IOAcceleratorFamily2 IOAcceleratorFamily2.kext/Contents/Info.plist; do
        [ -f "$KDK_EXT/$dep" ] || { echo "build-all.sh: missing Tahoe KDK input $KDK_EXT/$dep" >&2; exit 1; }
    done
fi

# Stale bundles from an earlier run must not survive as if they were built now.
for t in Sequoia Tahoe; do rm -rf "$X/out/target/$t"; done
[ "$TARGET" = tahoe ] || RAPHAELI_FW_SRC="$FW_SOURCE" RAPHAELI_OUT=out/target/Sequoia bash "$X/scripts/build.sh"
if [ "$TARGET" = all ]; then
    # build.sh already compiled every source; relink the same objects for the Tahoe bundle.
    bash "$X/scripts/link.sh" "$X/out/target/Tahoe"
elif [ "$TARGET" = tahoe ]; then
    RAPHAELI_FW_SRC="$FW_SOURCE" RAPHAELI_OUT=out/target/Tahoe bash "$X/scripts/build.sh"
fi

if [ "$TARGET" != sequoia ]; then
    TAHOE_KEXT="$X/out/target/Tahoe/Raphaeli.kext"
    GATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/raphaeli-tahoe-gate.XXXXXX")
    # check-oc-injection.sh needs a fresh work dir (it writes the KextInject log there); dependencies precede Raphaeli.
    if ! bash "$X/scripts/check-oc-injection.sh" "$KEXTINJECT" "$TAHOE_KC" "$GATE_DIR/injection" \
        "$KDK_EXT/IOGraphicsFamily.kext/IOGraphicsFamily" "$KDK_EXT/IOGraphicsFamily.kext/Info.plist" \
        "$KDK_EXT/IOAcceleratorFamily2.kext/Contents/MacOS/IOAcceleratorFamily2" "$KDK_EXT/IOAcceleratorFamily2.kext/Contents/Info.plist" \
        "$TAHOE_KEXT/Contents/MacOS/Raphaeli" "$TAHOE_KEXT/Contents/Info.plist"; then
        rm -rf "$TAHOE_KEXT"
        echo "build-all.sh: Tahoe injection gate failed; out/target/Tahoe removed, not accepted (log in $GATE_DIR)" >&2
        exit 1
    fi
fi

echo "build-all.sh: $TARGET complete"
case "$TARGET" in
    all) echo "  out/target/Sequoia/Raphaeli.kext"; echo "  out/target/Tahoe/Raphaeli.kext (Tahoe injection gate passed)" ;;
    sequoia) echo "  out/target/Sequoia/Raphaeli.kext" ;;
    tahoe) echo "  out/target/Tahoe/Raphaeli.kext (Tahoe injection gate passed)" ;;
esac
