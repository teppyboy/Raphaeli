#!/bin/bash
# fw-bundle.test.sh [kext-dir]: firmware-in-bundle lane test. Run after link.sh: validates that the
# Raphaeli.kext bundle carries the complete required Phoenix firmware census both in
# Contents/Resources/firmware/amdgpu/ and as linked-in symbols (_nmx_fw_*_start, the table
# nmx_platform.cpp falls back to when FIRMWARE_ROOT has no staged copy).
set -euo pipefail
X=${GPU_SRC_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
OUT=${1:-$X/out-disp}
K="$OUT/Raphaeli.kext/Contents"
cd "$X"

fail=0
# single source of truth for the census: the REQUIRED list in Raphaeli/Firmware/stage.sh
for req in $(awk '/^REQUIRED="/{f=1;next} f&&/^"/{exit} f{print}' Raphaeli/Firmware/stage.sh); do
    if [ -f "$K/Resources/firmware/amdgpu/$req" ]; then
        echo "ok  resources  firmware/amdgpu/$req ($(wc -c < "$K/Resources/firmware/amdgpu/$req" | tr -d ' ') bytes)"
    else
        echo "MISSING resources firmware/amdgpu/$req"; fail=1
    fi
    if nm -gU "$K/MacOS/Raphaeli" | grep "_nmx_fw_$(echo "$req" | sed 's/\.bin$//; s/\./_/g')_start" >/dev/null; then
        echo "ok  embedded   firmware/amdgpu/$req"
    else
        echo "MISSING embedded firmware/amdgpu/$req"; fail=1
    fi
done
# regression (Tahoe prelink bisect): the table's extern "C" refs resolve as __nmx_fw_* after the
# C underscore prefix; any UNDEFINED nmx_fw symbol means the .incbin object's labels mismatch the
# table again and kxld prelink dies with Invalid Parameter on OC injection
if nm -m "$K/MacOS/Raphaeli" | grep '(undefined' | grep -q '_nmx_fw_'; then
    echo "UNDEFINED fw symbols in binary (asm label underscore mismatch)"; fail=1
fi
echo
if [ "$fail" != 0 ]; then
    echo "census: incomplete; re-run scripts/link.sh with the full firmware/amdgpu/ set staged"
    exit 1
fi
echo "census: all required Phoenix (gfx1103) firmware present in $OUT/Raphaeli.kext (Resources + embedded)"
