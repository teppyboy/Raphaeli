#!/bin/bash
# one.sh <src>: compile one source to logs/<name>.log; a failed compile leaves logs/<name>.failed (a separate file,
# because a text marker can be matched by register names such as SDMA0_SEM_WAIT_FAIL_TIMER_CNTL in warnings)
S=$(cd "$(dirname "$0")" && pwd)
n=$(basename "$1" .c)
LOG_ROOT=${NMX_LOG_ROOT:-$S/../logs}
mkdir -p "$LOG_ROOT"
rm -f "$LOG_ROOT/$n.failed"
"$S/cc.sh" "$1" > "$LOG_ROOT/$n.log" 2>&1 || touch "$LOG_ROOT/$n.failed"
