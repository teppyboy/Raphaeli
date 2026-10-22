#!/bin/bash
# build-all.test.sh: preflight tests for build-all.sh. No compile runs: every case must fail
# before the source build starts, so this needs no firmware, KDK, or OpenCore on the host.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/build-all.sh"
pass=0; fail=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/build-all-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
FW="$TMP/fw"; mkdir -p "$FW"
KDK="$TMP/kdk/System/Library/Extensions"; mkdir -p "$KDK"
FAKE_TOOL="$TMP/KextInject"; printf '#!/bin/bash\nexit 0\n' > "$FAKE_TOOL"; chmod +x "$FAKE_TOOL"
KC="$TMP/BootKernelExtensions.kc"; : > "$KC"

# t <name> <expected-exit> <pattern> <env...> -- <args...>
t() {
    local name=$1 want=$2 pattern=$3; shift 3
    local out got
    out=$(env "$@" 2>&1); got=$?
    if [ "$got" = "$want" ] && [[ $out == *"$pattern"* ]]; then
        echo "ok    $name"; pass=$((pass + 1))
    else
        echo "FAIL  $name (exit $got, want $want; pattern '$pattern')"; echo "$out" | sed 's/^/      /'
        fail=$((fail + 1))
    fi
}
tahoe_env=(RAPHAELI_OC_KEXTINJECT="$FAKE_TOOL" RAPHAELI_TAHOE_KC="$KC" RAPHAELI_TAHOE_KDK_EXT="$KDK")

t "unknown target rejected"          2 "usage:"      RAPHAELI_FW_SRC="$FW" bash "$SCRIPT" bogus
t "missing firmware fails closed"    1 "RAPHAELI_FW_SRC" bash "$SCRIPT" sequoia
t "tahoe needs KextInject"           1 "RAPHAELI_OC_KEXTINJECT" RAPHAELI_FW_SRC="$FW" bash "$SCRIPT" tahoe
t "all needs Tahoe KC"               1 "RAPHAELI_TAHOE_KC" RAPHAELI_FW_SRC="$FW" RAPHAELI_OC_KEXTINJECT="$FAKE_TOOL" bash "$SCRIPT" all
t "tahoe KDK deps checked"           1 "missing Tahoe KDK input" RAPHAELI_FW_SRC="$FW" "${tahoe_env[@]}" bash "$SCRIPT" tahoe
mkdir -p "$KDK/IOGraphicsFamily.kext"; : > "$KDK/IOGraphicsFamily.kext/IOGraphicsFamily"; : > "$KDK/IOGraphicsFamily.kext/Info.plist"
t "tahoe KDK partial deps rejected"  1 "IOAcceleratorFamily2" RAPHAELI_FW_SRC="$FW" "${tahoe_env[@]}" bash "$SCRIPT" tahoe

echo "build-all tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
