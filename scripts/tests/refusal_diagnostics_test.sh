#!/bin/bash
# Static checks for display-bridge refusal accounting. No kernel SDK required.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FILE="$ROOT/Raphaeli/Override/src/nmx_dm_bridge.c"
fail=0
ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=$((fail + 1)); }
assert_fixed() {
  grep -Fq -- "$1" "$FILE" && ok "$2" || bad "$2"
}

if grep -Fq '__ATOMIC_' "$FILE" || grep -Eq '(^|[^_[:alnum:]])printf[[:space:]]*[(]' "$FILE"; then
  bad "bridge uses project-compatible atomic/logging APIs"
else
  ok "bridge uses project-compatible atomic/logging APIs"
fi
assert_fixed 'atomic_fetchadd_int(&dm_refusals[stage], 1)' "refusal counter uses FreeBSD atomic API"
assert_fixed 'device_printf(NULL, "Raphaeli dm bridge: refusal stage=' "refusal logger uses kernel device logging"
for stage in mode-input mode-device mode-connector mode-detach mode-stream-create mode-validate mode-commit flip-plane-create flip-update; do
  assert_fixed "\"$stage\"" "refusal stage name $stage is defined"
done
for stage in DM_REFUSE_MODE_INPUT DM_REFUSE_MODE_DEVICE DM_REFUSE_MODE_CONNECTOR DM_REFUSE_MODE_DETACH DM_REFUSE_STREAM_CREATE DM_REFUSE_VALIDATE DM_REFUSE_COMMIT DM_REFUSE_FLIP_PLANE_CREATE DM_REFUSE_FLIP_UPDATE; do
  assert_fixed "dm_refused($stage" "error path records $stage"
done
exit "$fail"
