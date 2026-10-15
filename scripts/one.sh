#!/bin/bash
# one.sh <src>: compile one source to logs/<name>.log; a failed compile leaves logs/<name>.failed (a separate file,
# because a text marker can be matched by register names such as SDMA0_SEM_WAIT_FAIL_TIMER_CNTL in warnings)
S=$(cd "$(dirname "$0")" && pwd)
n=$(basename "$1" .c)
rm -f logs/$n.failed
"$S/cc.sh" "$1" > logs/$n.log 2>&1 || touch logs/$n.failed
