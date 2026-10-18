#!/bin/bash
# ccxx.sh <source.cpp>: compiles one IOKit-side file with the pinned kernel SDK.
X=${GPU_SRC_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
. "$X/scripts/kernel-sdk.sh"
mkdir -p $X/xnuobj
# nmxxnu/ holds the two boundary headers for the IOKit side (which must not see the FreeBSD include tree); they are
# copies of bsdcompat/include's, refreshed here so a declaration added there always reaches the C++ side
cp -p $X/Raphaeli/Compat/include/nmx_port.h $X/Raphaeli/Compat/include/nmx_xnu.h $X/Raphaeli/Compat/include/nmxxnu/
target_flags=""
case "${NMX_TARGET:-sequoia}:$(basename "$1")" in
  tahoe:nmx_accel*)
    [ -n "${NMX_ACCEL_HEADERS:-}" ] || { echo "ccxx.sh: Tahoe accelerator headers not prepared" >&2; exit 1; }
    target_flags="-DNM_TAHOE -I$NMX_ACCEL_HEADERS" ;;
esac
exec xcrun clang++ -arch x86_64 -mmacosx-version-min=15.0 -ffile-prefix-map=${GPU_SRC_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}=/src -mkernel -fapple-kext -nostdinc $KERNEL_SDK_INCLUDE \
  -I$X/Raphaeli/Compat/include/nmxxnu -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT \
  -std=c++17 -fno-rtti -fno-exceptions -fno-builtin -fno-common -O2 -g0 -Wall -Wno-unused-parameter \
  -Wno-deprecated-declarations -Wno-inconsistent-missing-override $target_flags -c "$1" -o ${NMX_OBJ:-${NMX_OBJ_ROOT:-$X/xnuobj}/$(basename "${1%.cpp}").o}
