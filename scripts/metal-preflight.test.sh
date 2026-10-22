#!/bin/bash
# Host test for metal-preflight.sh: fixture roots only, no system changes. Bash 3.2 compatible.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
PRE="$HERE/metal-preflight.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { # check <name> <expected-rc> <expected-grep> <cmd...>
    local name=$1 want=$2 pat=$3; shift 3
    local out; out=$("$@" 2>&1); local got=$?
    if [ "$got" = "$want" ] && echo "$out" | grep -q -- "$pat"; then pass=$((pass + 1))
    else fail=$((fail + 1)); echo "FAIL $name (rc=$got want=$want)"; echo "$out"; fi
}

# Empty root: every layer blocked, exit 2.
mkdir -p "$T/empty/Raphaeli"; : > "$T/empty/Raphaeli/Info.plist"
check empty-root 2 "BLOCKED metal-plugin-objc" env METAL_PREFLIGHT_ROOT="$T/empty" METAL_PREFLIGHT_DEV_DRI="$T/nodri" "$PRE"

# Fully provisioned root: all layers ready, exit 0.
F=$T/full
mkdir -p "$F/out/usr/lib" "$F/work-metalplugin/smoke/target/debug" "$F/Raphaeli/Metal" "$T/dri"
echo x > "$F/out/usr/lib/libvulkan_radeon.dylib"; echo '{}' > "$F/out/usr/lib/radeon_icd.x86_64.json"
echo x > "$F/work-metalplugin/smoke/target/debug/m2v-smoke"; chmod +x "$F/work-metalplugin/smoke/target/debug/m2v-smoke"
echo x > "$F/Raphaeli/Metal/NMXMetalDevice.m"; echo '<key>MetalPluginName</key>' > "$F/Raphaeli/Info.plist"
echo x > "$T/dri/card0"
check full-root 0 "ready   metal-plugin-registration" env METAL_PREFLIGHT_ROOT="$F" METAL_PREFLIGHT_DEV_DRI="$T/dri" "$PRE"

# Provisioned plugin source but no MetalPluginName registration: registration layer stays BLOCKED.
U=$T/unregistered
cp -R "$F" "$U"; echo '<key>Other</key>' > "$U/Raphaeli/Info.plist"
check unregistered-plugin 2 "BLOCKED metal-plugin-registration" env METAL_PREFLIGHT_ROOT="$U" METAL_PREFLIGHT_DEV_DRI="$T/dri" "$PRE"

echo "metal-preflight tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
