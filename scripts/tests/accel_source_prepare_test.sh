#!/bin/bash
# Reproducibility checks for tracked accelerator headers and Tahoe ABI gating.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/raphaeli-accel-source.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
fail=0
ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=$((fail + 1)); }

python3 "$ROOT/scripts/prepare-accel-sources.py" --target sequoia --check-only && ok "tracked Sequoia source lock validates" || bad "tracked Sequoia source lock validates"
python3 "$ROOT/scripts/prepare-accel-sources.py" --target sequoia --output "$TMP/a" && ok "Sequoia source preparation succeeds" || bad "Sequoia source preparation succeeds"
python3 "$ROOT/scripts/prepare-accel-sources.py" --target sequoia --output "$TMP/b" && ok "Sequoia source preparation repeats" || bad "Sequoia source preparation repeats"
if diff -ru "$TMP/a" "$TMP/b"; then ok "Sequoia preparation is deterministic"; else bad "Sequoia preparation is deterministic"; fi
if python3 "$ROOT/scripts/prepare-accel-sources.py" --target tahoe --check-only >"$TMP/tahoe.log" 2>&1; then
  bad "unvalidated Tahoe ABI is refused"
else
  grep -Fq "26.7.1" "$TMP/tahoe.log" && grep -Fq "26.6.2 build 25G83" "$TMP/tahoe.log" && ok "unvalidated Tahoe ABI is refused" || bad "unvalidated Tahoe ABI is refused"
fi
[ -f "$TMP/a/nmx_accel_tahoe_forwarding.h" ] && ok "Tahoe forwarding generation is present in prepared tree" || bad "Tahoe forwarding generation is present in prepared tree"
[ -f "$ROOT/Raphaeli/Kernel/Accel/upstream/SOURCE.lock" ] && ok "source provenance is tracked" || bad "source provenance is tracked"
exit "$fail"
