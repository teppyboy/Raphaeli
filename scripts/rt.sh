#!/bin/bash
# rt.sh: rebuilds the port's runtime against the current headers: LinuxKPI's runtime sources (forks from
# override/src replace the originals of the same name; sources the port replaces or does not use are left out),
# the port's own LinuxKPI-side files, bsdcompat/src and the xnu glue. Prints failures only, then counts.
R=${GPU_SRC_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
X=$R
L=$R/kpi/freebsd-src/sys/compat/linuxkpi/common/src
cd "$X" || exit 1
TARGET_SELECTOR=sequoia
while [ "$#" -gt 0 ]; do
    case "$1" in
        --target) shift; [ "$#" -gt 0 ] || { echo "rt.sh: --target requires sequoia, tahoe, or all" >&2; exit 1; }; TARGET_SELECTOR=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]') ;;
        --target=*) TARGET_SELECTOR=$(printf '%s' "${1#--target=}" | tr '[:upper:]' '[:lower:]') ;;
        --help|-h) echo "usage: scripts/rt.sh --target sequoia|tahoe|all"; exit 0 ;;
        *) echo "rt.sh: unknown option $1" >&2; exit 1 ;;
    esac
    shift
done
case "$TARGET_SELECTOR" in sequoia|tahoe|all) ;; *) echo "rt.sh: unsupported target '$TARGET_SELECTOR'" >&2; exit 1 ;; esac
# networking, USB and wireless are not part of the GPU driver; i2c/i2cbb are replaced by nmx_linux_i2c.c;
# cmdline and eventfd are unused (drm-kmod's own headers answer them)
SKIP=" linux_80211 linux_80211_macops linuxkpi_80211_pm linux_netdev linux_usb linux_i2c linux_i2cbb linux_cmdline linux_eventfd "
run_target() {
    target=$1
    case "$target" in sequoia) name=Sequoia ;; tahoe) name=Tahoe ;; esac
    objroot="$X/obj/target/$name"
    mkdir -p "$objroot/lkobj" "$objroot/srcobj" "$objroot/xnuobj" "$X/logs/target/$name"
    fail=0; n=0
    export NMX_TARGET="$target" NMX_OBJ_ROOT="$objroot/lkobj" NMX_LOG_ROOT="$X/logs/target/$name"
    OVERRIDE_SRC=$X/Raphaeli/Override/src
    for f in $L/*.c $OVERRIDE_SRC/*.c; do
    b=$(basename "$f" .c)
    case "$SKIP" in *" $b "*) continue ;; esac
    [ "$f" != "$OVERRIDE_SRC/$b.c" ] && [ -f "$OVERRIDE_SRC/$b.c" ] && continue
    n=$((n + 1))
    "$X/scripts/cclk.sh" "$f" > "$NMX_LOG_ROOT/lk_$b.log" 2>&1 || { echo "LK FAIL $b"; fail=$((fail + 1)); }
done
# Concurrency Kit's epoch reclamation (BSD-2-Clause), under LinuxKPI's RCU
CK=$R/kpi/freebsd-src/sys/contrib/ck/src
n=$((n + 1))
"$X/scripts/cclk.sh" "$CK/ck_epoch.c" > "$NMX_LOG_ROOT/lk_ck_epoch.log" 2>&1 || { echo "LK FAIL ck_epoch"; fail=$((fail + 1)); }
for f in $X/Raphaeli/Compat/src/*.c $X/Raphaeli/Override/display/*.c; do
    b=$(basename "$f" .c); n=$((n + 1))
    NMX_OBJ_ROOT="$objroot/srcobj" "$X/scripts/ccsrc.sh" "$f" > "$NMX_LOG_ROOT/src_$b.log" 2>&1 || { echo "SRC FAIL $b"; fail=$((fail + 1)); }
done
for f in $X/Raphaeli/Kernel/*.cpp; do
    b=$(basename "$f" .cpp); n=$((n + 1))
    NMX_OBJ_ROOT="$objroot/xnuobj" "$X/scripts/ccxx.sh" "$f" > "$NMX_LOG_ROOT/xnu_$b.log" 2>&1 || { echo "XNU FAIL $b"; fail=$((fail + 1)); }
done
echo "$target runtime sources: $n  failed: $fail"
[ "$fail" -eq 0 ]
}
case "$TARGET_SELECTOR" in all) run_target sequoia && run_target tahoe ;; *) run_target "$TARGET_SELECTOR" ;; esac
