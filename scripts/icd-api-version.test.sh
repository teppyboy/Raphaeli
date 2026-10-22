#!/bin/bash
# icd-api-version.test.sh: host test for icd-api-version.sh. Fixture manifests only; no build, no system changes.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/icd-api-version.sh"
pass=0; fail=0
T=$(mktemp -d "${TMPDIR:-/tmp}/icd-api-test.XXXXXX")
trap 'rm -rf "$T"' EXIT

# manifest <name> <json-body>: write a fixture ICD manifest.
manifest() { printf '%s\n' "$2" > "$T/$1.json"; }

# t <name> <expected-exit> <expected-stdout-or-empty> <file>
t() {
    local name=$1 want=$2 stdout=$3 file=$4 out got
    out=$(icd_api_version "$file"); got=$?
    if [ "$got" = "$want" ] && [ "$out" = "$stdout" ]; then
        echo "ok    $name"; pass=$((pass + 1))
    else
        echo "FAIL  $name (exit $got, want $want; stdout '$out', want '$stdout')"; fail=$((fail + 1))
    fi
}

manifest mesa363 '{"ICD": {"api_version": "1.4.363", "library_path": "/x/libvulkan_radeon.dylib"}, "file_format_version": "1.0.1"}'
manifest mesa400 '{"ICD": {"api_version": "1.4.400", "library_path": "/x/libvulkan_radeon.dylib"}, "file_format_version": "1.0.1"}'
manifest noKey '{"ICD": {"library_path": "/x/libvulkan_radeon.dylib"}, "file_format_version": "1.0.1"}'
manifest shortVer '{"ICD": {"api_version": "1.4", "library_path": "/x"}}'
manifest garbage '{"ICD": {"api_version": "1.4.363; rm -rf /"}}'
printf '{not json' > "$T/broken.json"

t "reads Mesa-generated api_version" 0 "1.4.363" "$T/mesa363.json"
t "value is derived, not fixed" 0 "1.4.400" "$T/mesa400.json"
t "missing manifest fails closed" 1 "" "$T/absent.json"
t "malformed JSON fails closed" 1 "" "$T/broken.json"
t "missing api_version fails closed" 1 "" "$T/noKey.json"
t "two-part version fails closed" 1 "" "$T/shortVer.json"
t "non-version text fails closed" 1 "" "$T/garbage.json"

echo "icd api_version tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
