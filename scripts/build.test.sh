#!/bin/bash
# build.test.sh: target selector parser tests. These cases fail before any build inputs are needed.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/build.sh"
pass=0; fail=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/build-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

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

t "unsupported target rejected" 1 "unsupported target" bash "$SCRIPT" --target invalid
t "duplicate target rejected" 1 "specified more than once" bash "$SCRIPT" --target sequoia --target=tahoe

echo "build tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
