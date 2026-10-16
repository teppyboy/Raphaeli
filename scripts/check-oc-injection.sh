#!/bin/bash
# Host-only gate using OpenCorePkg Utilities/TestKextInject (no driver load).
# Tool writes out.bin; use a NEW scratch directory, never the input KC directory.
set -euo pipefail
if [ "$#" -lt 5 ] || [ $((($# - 3) % 2)) -ne 0 ]; then
    echo "usage: $0 <KextInject-tool> <BootKernelExtensions.kc> <new-scratch-dir> <binary> <plist> [<binary> <plist> ...]" >&2
    exit 1
fi
BASE=$PWD
TOOL=$1; KC=$2; WORK=$3; shift 3
case "$TOOL" in /*) ;; *) TOOL="$BASE/$TOOL" ;; esac
case "$KC" in /*) ;; *) KC="$BASE/$KC" ;; esac
[ -x "$TOOL" ] && [ -f "$KC" ] || { echo 'Missing executable KextInject or input KC' >&2; exit 1; }
# Rotate arguments once to preserve pairs while making paths absolute before cd.
remaining=$#
while [ "$remaining" -gt 0 ]; do
    arg=$1; shift
    case "$arg" in /*) ;; *) arg="$BASE/$arg" ;; esac
    [ -f "$arg" ] || { echo "Missing input: $arg" >&2; exit 1; }
    set -- "$@" "$arg"
    remaining=$((remaining - 1))
done
mkdir "$WORK"
WORK=$(cd "$WORK" && pwd)
rc=0
(cd "$WORK" && "$TOOL" "$KC" "$@") > "$WORK/injection.log" 2>&1 || rc=$?
# TestKextInject returns -1 (255) for unrelated bundled quirk tests too.
case "$rc" in 0|255) ;; *) echo "KextInject terminated unexpectedly ($rc): $WORK/injection.log" >&2; exit 1 ;; esac
failed=0
while [ "$#" -gt 0 ]; do
    binary=$1; shift 2
    if grep -F "[OK] $binary injected - Success (" "$WORK/injection.log" >/dev/null; then
        printf 'PASS: %s\n' "$binary"
    else
        printf 'FAIL: %s\n' "$binary" >&2
        failed=1
    fi
done
if grep -E '\[FAIL\].*injected -|Vtable patching failed|Symbol .* has 0-value' "$WORK/injection.log" >/dev/null; then
    failed=1
fi
if ! grep -F '[OK] Prelink inject complete success' "$WORK/injection.log" >/dev/null; then
    failed=1
fi
printf 'Prelink log: %s/injection.log\n' "$WORK"
[ "$failed" = 0 ]
