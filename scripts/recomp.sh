#!/bin/bash
# recompile only current .failed files
X=${GPU_SRC_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
cd "$X" || exit 1
names=$(ls logs/*.failed 2>/dev/null | xargs -n1 basename | sed 's/\.failed$//')
[ -z "$names" ] && { echo "nothing failed"; exit 0; }
pat=$(echo "$names" | sed 's#^#/#; s#$#\.c$#; s#\.#\\.#g' | paste -sd'|' -)
# srcs.txt lists bare filenames under dir headers; expand with find
> /tmp/recomp.list
for n in $names; do
  f=$(find kpi/drm-kmod -name "$n.c" | head -1)
  [ -n "$f" ] && echo "$f" >> /tmp/recomp.list
done
wc -l < /tmp/recomp.list
xargs -P 10 -I{} "$X/scripts/one.sh" {} < /tmp/recomp.list
