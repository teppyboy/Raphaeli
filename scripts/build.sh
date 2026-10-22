#!/bin/bash
# build.sh [--target sequoia|tahoe|all] [N]: compile AMD/DRM/TTM sources.
set -u
GPU_SRC_ROOT=${GPU_SRC_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
X=$GPU_SRC_ROOT
K=$GPU_SRC_ROOT/kpi
cd "$X" || exit 1

TARGET_SELECTOR=sequoia
TARGET_OPTION_SEEN=0
RANK=40
while [ "$#" -gt 0 ]; do
    case "$1" in
        --target)
            [ "$TARGET_OPTION_SEEN" -eq 0 ] || { echo "build.sh: --target specified more than once" >&2; exit 1; }
            TARGET_OPTION_SEEN=1
            shift; [ "$#" -gt 0 ] || { echo "build.sh: --target requires sequoia, tahoe, or all" >&2; exit 1; }
            TARGET_SELECTOR=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]') ;;
        --target=*)
            [ "$TARGET_OPTION_SEEN" -eq 0 ] || { echo "build.sh: --target specified more than once" >&2; exit 1; }
            TARGET_OPTION_SEEN=1
            TARGET_SELECTOR=$(printf '%s' "${1#--target=}" | tr '[:upper:]' '[:lower:]') ;;
        --help|-h) echo "usage: scripts/build.sh [--target sequoia|tahoe|all] [N]"; exit 0 ;;
        --*) echo "build.sh: unknown option $1" >&2; exit 1 ;;
        *) RANK=$1 ;;
    esac
    shift
done
case "$TARGET_SELECTOR" in sequoia|tahoe|all) ;; *) echo "build.sh: unsupported target '$TARGET_SELECTOR'" >&2; exit 1 ;; esac
# Tahoe forwarding is generated from tracked source, but the pinned ABI (26.7.1) is not
# validated against the audited 26.6.2/25G83 target. Preflight all before creating outputs.
if [ "$TARGET_SELECTOR" = tahoe ] || [ "$TARGET_SELECTOR" = all ]; then
    python3 "$X/scripts/prepare-accel-sources.py" --target tahoe --check-only 2>&1 || {
        echo "build.sh: refusing $TARGET_SELECTOR before compiling; missing matching Tahoe ABI header (exact target audit required)" >&2
        exit 1
    }
fi
bash "$X/scripts/kpi-init.sh" || exit 1

# Sources are exactly what drm-kmod's Makefiles build for amdgpu (minus the display core), drm, ttm and dmabuf,
# evaluated against amd.flags, minus files that are GPL-only or built on FreeBSD file descriptors or its console;
# the port supplies its own code for those.
EXCLUDE="amdgpu_dm_crc.c drm_gem_ttm_helper.c drm_writeback.c drm_hdcp_helper.c sync_file.c dma-fence-unwrap.c dma-buf.c dma-buf-kmod.c linux_fb.c vt_drmfb.c drm_os_freebsd.c"
python3 "$X/scripts/srclist.py" "$K/drm-kmod" "$X/scripts/amd.flags" amd/amdgpu drm ttm dmabuf 2>/dev/null > srcs.all
: > srcs.txt
while read -r f; do
    case " $EXCLUDE " in *" $(basename "$f") "*) ;; *) echo "$f" >> srcs.txt ;; esac
done < srcs.all
# DRM sources drm-kmod builds in other modules that the AMD driver also calls (MIT or GPL-2.0-or-MIT)
# drm_mipi_dsi.c: i915 drives DSI panels through it (MIT)
for e in drm_client.c drm_client_modeset.c drm_panel_orientation_quirks.c drm_mipi_dsi.c; do echo "$K/drm-kmod/drivers/gpu/drm/$e" >> srcs.txt; done
EXPECTED=900

# Firmware is intentionally not vendored. An explicit source is mandatory so a
# successful build cannot accidentally embed an incomplete or stale local set.
FW_SOURCE=${RAPHAELI_FW_SRC:-}
[ -n "$FW_SOURCE" ] && [ -d "$FW_SOURCE" ] || {
    echo "build.sh: set RAPHAELI_FW_SRC to a linux-firmware/amdgpu directory" >&2
    exit 1
}
# Build both pinned userspace submodules; no pre-existing out/usr artifacts are
# accepted. zstd and SPIR-V tools are build-time options here, avoiding hidden
# host dylib dependencies in the distributable RADV binary.
command -v meson >/dev/null 2>&1 || { echo "build.sh: meson is required" >&2; exit 1; }
command -v ninja >/dev/null 2>&1 || { echo "build.sh: ninja is required" >&2; exit 1; }
command -v glslangValidator >/dev/null 2>&1 || { echo "build.sh: glslangValidator is required (glslang package)" >&2; exit 1; }
FW_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/raphaeli-fw.XXXXXX")
trap 'rm -rf "$FW_STAGE"' EXIT
sh "$X/Raphaeli/Firmware/stage.sh" "$FW_SOURCE" "$FW_STAGE" || exit 1
rm -rf "$X/firmware/amdgpu"
mkdir -p "$X/firmware/amdgpu"
cp "$FW_STAGE/amdgpu/"*.bin "$X/firmware/amdgpu/"

USR="$X/out/usr"
rm -rf "$USR"
mkdir -p "$USR"
LBUILD="$X/work-libdrm/build-darwin"
if [ -d "$LBUILD" ]; then WIPE=--wipe; else WIPE=; fi
meson setup $WIPE "$LBUILD" "$X/deps/libdrm" \
    -Dprefix="$USR" -Damdgpu=enabled -Dintel=disabled -Dradeon=disabled \
    -Dnouveau=disabled -Dvmwgfx=disabled -Dtests=false -Dman-pages=disabled
ninja -C "$LBUILD" install
MBUILD="$X/work-mesa/build-darwin"
if [ -d "$MBUILD" ]; then WIPE=--wipe; else WIPE=; fi
PKG_CONFIG_PATH="$USR/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
meson setup $WIPE "$MBUILD" "$X/deps/mesa" \
    -Dprefix="$USR" -Dvulkan-drivers=amd -Dgallium-drivers= -Dglx=disabled \
    -Dplatforms= -Dbuild-tests=false -Dtools= -Dzstd=disabled -Dspirv-tools=disabled
ninja -C "$MBUILD" src/amd/vulkan/libvulkan_radeon.dylib
ninja -C "$MBUILD" install
for lib in libdrm.2.dylib libdrm_amdgpu.1.dylib libvulkan_radeon.dylib; do
    [ -s "$USR/lib/$lib" ] || { echo "build.sh: missing userspace output $USR/lib/$lib" >&2; exit 1; }
done
# Meson writes a host-path ICD; its api_version is the Mesa-derived value. The release manifest reuses
# that value at the fixed target install path. A missing or malformed value fails before any write.
. "$X/scripts/icd-api-version.sh"
API_VER=$(icd_api_version "$USR/share/vulkan/icd.d/radeon_icd.x86_64.json") || { echo "build.sh: cannot derive ICD api_version" >&2; exit 1; }
cat > "$USR/lib/radeon_icd.x86_64.json" <<EOF
{
    "ICD": {
        "api_version": "$API_VER",
        "library_arch": "64",
        "library_path": "/Library/Raphaeli/usr/lib/libvulkan_radeon.dylib"
    },
    "file_format_version": "1.0.1"
}
EOF

build_target() {
    target=$1
    case "$target" in sequoia) name=Sequoia ;; tahoe) name=Tahoe ;; esac
    obj="$X/obj/target/$name"; log="$X/logs/target/$name"
    ACCEL_HEADERS="$obj/accel-headers"
    python3 "$X/scripts/prepare-accel-sources.py" --target "$target" --output "$ACCEL_HEADERS" || exit 1
    export NMX_ACCEL_HEADERS="$ACCEL_HEADERS"
    mkdir -p "$obj" "$log"
    rm -f "$log"/*.log "$log"/*.failed
    n=$(wc -l < srcs.txt | tr -d ' ')
    NMX_TARGET="$target" NMX_OBJ_ROOT="$obj" NMX_LOG_ROOT="$log" export NMX_TARGET NMX_OBJ_ROOT NMX_LOG_ROOT
    # xargs returns nonzero when a compiler fails; the source gate below reports the counts and diagnostics.
    xargs -P 10 -n 1 "$X/scripts/one.sh" < srcs.txt || echo "build.sh: $target source compilations failed; evaluating source gate" >&2
    bad=$(find "$log" -name '*.failed' -type f -print 2>/dev/null | wc -l | tr -d ' ')
    compiled=$((n - bad))
    echo "$target sources: $n  compiled: $compiled  failed: $bad"
    for f in "$log"/*.failed; do [ -e "$f" ] && cat "${f%.failed}.log"; done | grep -h "error:" | sed -E 's|^[^ ]*/([^/]+:[0-9]+):[0-9]+: error: |\1 |' | sed -E 's/^[^ ]+ //' | sort | uniq -c | sort -rn | head -"$RANK"
    [ "$n" -eq "$EXPECTED" ] && [ "$bad" -eq 0 ] || {
        echo "build.sh: $target AMD source gate failed ($compiled/$n; expected $EXPECTED/$EXPECTED)" >&2
        return 1
    }
}
case "$TARGET_SELECTOR" in
    all) build_target sequoia && build_target tahoe ;;
    *) build_target "$TARGET_SELECTOR" ;;
esac
