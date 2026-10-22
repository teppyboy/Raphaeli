#!/bin/bash
# Host test for the Metal C shim: builds Raphaeli/Metal/nmx_metal_shim.c with the test driver and runs it.
# Host clang only, no system changes. Bash 3.2 compatible.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
clang -std=c11 -Wall -Wextra -Werror -I "$ROOT/Raphaeli/Metal" \
    "$ROOT/Raphaeli/Metal/nmx_metal_shim.c" "$ROOT/scripts/tests/nmx_metal_shim_test.c" -o "$T/shim_test"
"$T/shim_test"
