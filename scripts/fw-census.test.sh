#!/bin/bash
# fw-census.test.sh: host assertion for the Phoenix firmware census and the
# pinned amdgpu cleaner-shader enablement gate. No build output or hardware needed.
set -euo pipefail
X=${GPU_SRC_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
cd "$X"

fail=0
TMP=${TMPDIR:-/tmp}/raphaeli-fw-census.$$
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP"

cat > "$TMP/expected" <<'EOF'
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
EOF
awk '/^REQUIRED="/{f=1;next} f&&/^"/{exit} f{print}' Raphaeli/Firmware/stage.sh > "$TMP/actual"
if cmp -s "$TMP/expected" "$TMP/actual"; then
    echo "ok    exact Phoenix (gfx1103) REQUIRED firmware census (11 files)"
else
    echo "FAIL  REQUIRED census differs from expected gfx1103 census"
    diff -u "$TMP/expected" "$TMP/actual" || true
    fail=1
fi

GFX=kpi/drm-kmod/drivers/gpu/drm/amd/amdgpu/gfx_v11_0.c
for needle in \
    'case IP_VERSION(11, 0, 0):' \
    'case IP_VERSION(11, 0, 2):' \
    'case IP_VERSION(11, 0, 3):' \
    'adev->gfx.me_fw_version  >= 2280' \
    'adev->gfx.pfp_fw_version >= 2370' \
    'adev->gfx.mec_fw_version >= 2450' \
    'adev->mes.fw_version[0] >= 99'; do
    if grep -F "$needle" "$GFX" >/dev/null; then
        echo "ok    pinned cleaner-shader gate: $needle"
    else
        echo "FAIL  pinned cleaner-shader gate missing: $needle"
        fail=1
    fi
done

if [ "$fail" != 0 ]; then
    exit 1
fi
echo "census: exact gfx1103 set; cleaner shader remains pinned amdgpu threshold-gated"
