#!/bin/bash
# Compatibility entry point for the target-aware release package fixture.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
bash "$HERE/scripts/tests/package_target_test.sh"
