#!/bin/bash
# link.sh [out-dir]: links Raphaeli.kext from obj/ (AMD/DRM/TTM), lkobj/ (LinuxKPI runtime),
# srcobj/ (FreeBSD-on-xnu layer) and xnuobj/ (IOKit glue). Run build.sh + rt.sh first.
set -euo pipefail
X=${GPU_SRC_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
OUT=${1:-$X/out}
cd "$X"

# stale non-Mach-O objects from failed header compiles would abort the link
for f in obj/*.o lkobj/*.o srcobj/*.o xnuobj/*.o; do
    file -b "$f" | grep -q Mach-O || { echo "stale object: $f"; rm "$f"; }
done

K="$OUT/Raphaeli.kext/Contents"
mkdir -p "$K/MacOS"
xcrun clang -arch x86_64 -mmacosx-version-min=15.0 -fapple-kext -nostdlib -Xlinker -kext \
  -Xlinker -source_version -Xlinker 1.0.0 \
  obj/*.o lkobj/*.o srcobj/*.o xnuobj/nmx_kext.o xnuobj/nmx_devfs.o xnuobj/nmx_dma.o \
  xnuobj/nmx_fb.o xnuobj/nmx_accel.o xnuobj/nmx_accel_uc.o xnuobj/nmx_mm.o xnuobj/nmx_pci.o xnuobj/nmx_platform.o xnuobj/nmx_vm.o \
  -lkmodc++ -lkmod -lcc_kext -o "$K/MacOS/Raphaeli" 2> link.log || {
    grep -E "error|Undefined|duplicate" link.log | head -40; exit 1; }
cp "$X/Raphaeli/Info.plist" "$K/Info.plist"
echo "Raphaeli $(shasum -a 256 "$K/MacOS/Raphaeli" | cut -c1-8) $(stat -f %z "$K/MacOS/Raphaeli") B"
# kmutil silently classifies kexts not owned by root:wheel as codeless ('No binaries or
# codeless kexts were provided') regardless of signature; fix ownership before building the auxKC:
#   sudo chown -R root:wheel "$OUT/Raphaeli.kext" && sudo chmod -R 755 "$OUT/Raphaeli.kext"
#   kmutil create -a x86_64 -n aux -x -p "$OUT/Raphaeli.kext" --no-authentication \
#     -A /tmp/raphaeli-auxkc -B /System/Library/KernelCollections/BootKernelExtensions.kc \
#     -S /System/Library/KernelCollections/SystemKernelExtensions.kc \
#     --kdk /Library/Developer/KDKs/KDK_15.7.8_24G824.kdk
if [ "$(stat -f %u "$K/MacOS/Raphaeli")" != 0 ]; then
    echo "WARNING: Raphaeli.kext not owned by root:wheel; kmutil will treat it as codeless. Run the chown above."
fi
