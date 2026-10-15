#!/bin/sh
# Stage AMD (Phoenix / Radeon 780M / gfx1103, PCI 0x15bf) firmware blobs into the
# layout nmx_platform.cpp expects: DEST/amdgpu/<name>.bin under
# /Library/Raphaeli/firmware/ (FIRMWARE_ROOT in xnu/nmx_platform.cpp).
#
# Usage: stage.sh <source-dir-with-linux-firmware-amdgpu-blobs> [dest-dir]
#
# Names are exactly the strings amdgpu passes to request_firmware(); see
# amdgpu_discovery.c (ip_discovery.bin - OPTIONAL: never shipped upstream for
# GC11; default amdgpu_discovery=-1 reads discovery from VRAM TMR, the file is
# only used by opt-in amdgpu_discovery=2), gfx_v11_0.c, imu_v11_0.c, mes_v11_0.c /
# amdgpu_mes.c (GC 11.0.1), sdma_v6_0.c (6.0.2), psp_v13_0.c (13.0.11),
# amdgpu_vcn.c (4.0.2/4.0.4), display/amdgpu_dm/amdgpu_dm.c (DCN 3.1.4 dmcub).
set -u

SRC=${1:?usage: stage.sh <source-amdgpu-blob-dir> [dest-dir]}
DEST=${2:?usage: stage.sh <source-amdgpu-blob-dir> [dest-dir]}

# required = kext fails init without it; optional = only some configs load it
REQUIRED="
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
"
OPTIONAL="
ip_discovery.bin
gc_11_0_1_toc.bin
gc_11_0_1_mes_2.bin
gc_11_0_1_mes.bin
vcn_4_0_4.bin
"

REQ=$(echo $REQUIRED)   # collapse newlines for the case match below
mkdir -p "$DEST/amdgpu" || exit 1
missing=0
for f in $REQUIRED $OPTIONAL; do
    if [ -f "$SRC/$f" ]; then
        cp "$SRC/$f" "$DEST/amdgpu/$f" || exit 1
        echo "staged  amdgpu/$f ($(wc -c < "$SRC/$f" | tr -d ' ') bytes)"
    else
        case " $REQ " in
        *" $f "*) echo "MISSING amdgpu/$f (REQUIRED)"; missing=$((missing + 1)) ;;
        *) echo "missing amdgpu/$f (optional; ignored unless the feature is used)" ;;
        esac
    fi
done
echo
if [ "$missing" -gt 0 ]; then
    echo "census: $missing REQUIRED file(s) missing; install into: $DEST/amdgpu/"
    exit 1
fi
echo "census: all required Phoenix (gfx1103) firmware staged under $DEST/amdgpu/"
