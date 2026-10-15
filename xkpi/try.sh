#!/bin/bash
# try.sh <src>: compile, then show the first distinct errors (paths shortened)
cd ${GPU_SRC_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/xkpi
./cc.sh "$1" > last.log 2>&1
n=$(grep -c "error:" last.log)
echo "errors: $n"
grep -E "error:" last.log | sed -E "s|${GPU_SRC_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/||; s|kpi/freebsd-src/sys/compat/linuxkpi/|LKPI/|; s|kpi/drm-kmod/|DK/|" | awk "!seen[\$0]++" | head -${2:-25}
