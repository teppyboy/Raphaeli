#!/bin/bash
# rt.sh: rebuilds the port's runtime against the current headers: LinuxKPI's runtime sources (forks from
# override/src replace the originals of the same name; sources the port replaces or does not use are left out),
# the port's own LinuxKPI-side files, bsdcompat/src and the xnu glue. Prints failures only, then counts.
X=${GPU_SRC_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
L=${GPU_SRC_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/kpi/freebsd-src/sys/compat/linuxkpi/common/src
cd "$X" || exit 1
# networking, USB and wireless are not part of the GPU driver; i2c/i2cbb are replaced by nmx_linux_i2c.c;
# cmdline and eventfd are unused (drm-kmod's own headers answer them)
SKIP=" linux_80211 linux_80211_macops linuxkpi_80211_pm linux_netdev linux_usb linux_i2c linux_i2cbb linux_cmdline linux_eventfd "
rm -f lkobj/*.o srcobj/*.o xnuobj/*.o
fail=0; n=0
OVERRIDE_SRC=$X/Raphaeli/Override/src
for f in $L/*.c $OVERRIDE_SRC/*.c; do
    b=$(basename "$f" .c)
    case "$SKIP" in *" $b "*) continue ;; esac
    [ "$f" != "$OVERRIDE_SRC/$b.c" ] && [ -f "$OVERRIDE_SRC/$b.c" ] && continue
    n=$((n + 1))
    "$X/scripts/cclk.sh" "$f" > "lklogs/$b.log" 2>&1 || { echo "LK FAIL $b"; fail=$((fail + 1)); }
done
# Concurrency Kit's epoch reclamation (BSD-2-Clause), under LinuxKPI's RCU
CK=${GPU_SRC_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/kpi/freebsd-src/sys/contrib/ck/src
n=$((n + 1))
"$X/scripts/cclk.sh" "$CK/ck_epoch.c" > lklogs/ck_epoch.log 2>&1 || { echo "LK FAIL ck_epoch"; fail=$((fail + 1)); }
for f in $X/Raphaeli/Compat/src/*.c $X/Raphaeli/Override/display/*.c; do
    b=$(basename "$f" .c); n=$((n + 1))
    "$X/scripts/ccsrc.sh" "$f" > "srclog_$b.txt" 2>&1 || { echo "SRC FAIL $b"; fail=$((fail + 1)); }
done
for f in $X/Raphaeli/Kernel/*.cpp; do
    b=$(basename "$f" .cpp); n=$((n + 1))
    "$X/scripts/ccxx.sh" "$f" > "xlog_$b.txt" 2>&1 || { echo "XNU FAIL $b"; fail=$((fail + 1)); }
done
echo "runtime sources: $n  failed: $fail"
