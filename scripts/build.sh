#!/bin/bash
# build.sh [--target sequoia|tahoe|all] [N]: compile AMD/DRM/TTM sources.
set -u
GPU_SRC_ROOT=${GPU_SRC_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
X=$GPU_SRC_ROOT
K=$GPU_SRC_ROOT/kpi
cd "$X" || exit 1

TARGET_SELECTOR=sequoia
RANK=40
while [ "$#" -gt 0 ]; do
    case "$1" in
        --target)
            shift; [ "$#" -gt 0 ] || { echo "build.sh: --target requires sequoia, tahoe, or all" >&2; exit 1; }
            TARGET_SELECTOR=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]') ;;
        --target=*) TARGET_SELECTOR=$(printf '%s' "${1#--target=}" | tr '[:upper:]' '[:lower:]') ;;
        --help|-h) echo "usage: scripts/build.sh [--target sequoia|tahoe|all] [N]"; exit 0 ;;
        --*) echo "build.sh: unknown option $1" >&2; exit 1 ;;
        *) RANK=$1 ;;
    esac
    shift
done
case "$TARGET_SELECTOR" in sequoia|tahoe|all) ;; *) echo "build.sh: unsupported target '$TARGET_SELECTOR'" >&2; exit 1 ;; esac
bash "$X/scripts/kpi-init.sh" || exit 1

EXCLUDE="amdgpu_dm_crc.c drm_gem_ttm_helper.c drm_writeback.c drm_hdcp_helper.c sync_file.c dma-fence-unwrap.c dma-buf.c dma-buf-kmod.c linux_fb.c vt_drmfb.c drm_os_freebsd.c"
python3 "$X/scripts/srclist.py" "$K/drm-kmod" "$X/scripts/amd.flags" amd/amdgpu drm ttm dmabuf 2>/dev/null > srcs.all
: > srcs.txt
while read -r f; do
    case " $EXCLUDE " in *" $(basename "$f") "*) ;; *) echo "$f" >> srcs.txt ;; esac
done < srcs.all
for e in drm_client.c drm_client_modeset.c drm_panel_orientation_quirks.c drm_mipi_dsi.c; do echo "$K/drm-kmod/drivers/gpu/drm/$e" >> srcs.txt; done

build_target() {
    target=$1
    case "$target" in sequoia) name=Sequoia ;; tahoe) name=Tahoe ;; esac
    obj="$X/obj/target/$name"; log="$X/logs/target/$name"
    mkdir -p "$obj" "$log"
    rm -f "$log"/*.log "$log"/*.failed
    n=$(wc -l < srcs.txt | tr -d ' ')
    NMX_TARGET="$target" NMX_OBJ_ROOT="$obj" NMX_LOG_ROOT="$log" export NMX_TARGET NMX_OBJ_ROOT NMX_LOG_ROOT
    xargs -P 10 -n 1 "$X/scripts/one.sh" < srcs.txt
    bad=$(ls "$log"/*.failed 2>/dev/null | wc -l | tr -d ' ')
    echo "$target sources: $n  compiled: $((n - bad))  failed: $bad"
    for f in "$log"/*.failed; do [ -e "$f" ] && cat "${f%.failed}.log"; done | grep -h "error:" | sed -E 's|^[^ ]*/([^/]+:[0-9]+):[0-9]+: error: |\1 |' | sed -E 's/^[^ ]+ //' | sort | uniq -c | sort -rn | head -"$RANK"
    [ "$bad" -eq 0 ]
}
case "$TARGET_SELECTOR" in
    all) build_target sequoia && build_target tahoe ;;
    *) build_target "$TARGET_SELECTOR" ;;
esac
