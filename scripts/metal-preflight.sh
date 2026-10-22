#!/bin/bash
# metal-preflight.sh: reports which layer between a macOS Metal app and RADV is missing. Prints one line per layer;
# exit 0 when every layer is ready, 2 when any is blocked. Read-only. Roots overridable for tests:
# METAL_PREFLIGHT_ROOT (repo root), METAL_PREFLIGHT_DEV_DRI (/dev/dri).
R=${METAL_PREFLIGHT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
DRI=${METAL_PREFLIGHT_DEV_DRI:-/dev/dri}
blocked=0
ok() { echo "ready   $1"; }
no() { echo "BLOCKED $1: $2"; blocked=$((blocked + 1)); }

[ -s "$R/out/usr/lib/libvulkan_radeon.dylib" ] && ok "radv-icd-library" || no "radv-icd-library" "out/usr/lib/libvulkan_radeon.dylib missing (run scripts/build.sh)"
[ -s "$R/out/usr/lib/radeon_icd.x86_64.json" ] && ok "radv-icd-manifest" || no "radv-icd-manifest" "out/usr/lib/radeon_icd.x86_64.json missing"
[ -x "$R/work-metalplugin/smoke/target/debug/m2v-smoke" ] && ok "metal2vulkan-smoke" || no "metal2vulkan-smoke" "work-metalplugin/smoke binary missing"
if [ -d "$DRI" ] && [ -n "$(ls "$DRI" 2>/dev/null)" ]; then ok "gpu-device-nodes"
else no "gpu-device-nodes" "$DRI has no nodes: NMXGPU kext not attached (needs raphaeli-amd=1 on target hardware)"; fi
ls "$R"/Raphaeli/Metal/*.m >/dev/null 2>&1 && ok "metal-plugin-objc" || no "metal-plugin-objc" "no ObjC Metal plugin source under Raphaeli/Metal/ (metal2vulkan runtime has no C ABI)"
grep -q "MetalPluginName" "$R/Raphaeli/Info.plist" && ok "metal-plugin-registration" || no "metal-plugin-registration" "RaphaeliAccel publishes no MetalPluginName, so Metal never loads a plugin"

[ "$blocked" -eq 0 ] && exit 0
echo "$blocked layer(s) blocked"
exit 2
