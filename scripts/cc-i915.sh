#!/bin/bash
# cc-i915.sh <source.c> [extra flags]: compiles one drm-kmod i915 source for the macOS kernel (x86_64) through the
# FreeBSD-on-xnu layer (bsdcompat) and FreeBSD LinuxKPI. drm-kmod's GPL-only linuxkpi/gplv2 headers are NOT on the path.
X=${GPU_SRC_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
K=${GPU_SRC_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/kpi
L=$K/freebsd-src/sys/compat/linuxkpi
D=$K/drm-kmod
A=$D/drivers/gpu/drm/amd
SDK=$(xcrun --sdk macosx --show-sdk-path)
KF=$SDK/System/Library/Frameworks/Kernel.framework/Headers
src=$1; shift
exec xcrun clang -arch x86_64 -mmacosx-version-min=15.0 -ffile-prefix-map=${GPU_SRC_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}=/src -mkernel -fapple-kext -nostdinc -std=gnu11 \
  -fno-builtin -fno-common -fno-strict-aliasing -fms-extensions -O2 -g0 \
  -Wno-pointer-sign -Wno-unused-parameter -Wno-microsoft-anon-tag -ferror-limit=80 \
  -D_KERNEL -DKERNEL -DKERNEL_PRIVATE -DLINUXKPI_VERSION=61400 -DNMXKPI=1 \
  -include $X/Raphaeli/Compat/include/nmxkpi_prelude.h \
  -include $L/common/include/linux/compiler_types.h -include $L/common/include/linux/kconfig.h -include $X/Raphaeli/Compat/include/nmxkpi_post.h \
  -I$X/Raphaeli/Override/include -I$X/Raphaeli/Compat/include -I$D/linuxkpi/bsd/include -I$L/common/include -I$L/dummy/include -I$X/fbroot \
  -I$D/include -I$D/include/drm -I$D/include/uapi -I$D/drivers/gpu/drm -I$D/drivers/gpu -I$D/drivers \
  -I$D/drivers/gpu/drm/i915 -I$D/drivers/gpu/drm/i915/display -I$D/drivers/gpu/drm/i915/gem -DI915 \
  $(grep -v "KBUILD_MODNAME\|PARAM_PREFIX\|/drm/amd" $X/scripts/amd.flags | sed "s/^/ /" | tr "\n" " ") '-DKBUILD_MODNAME="i915kms"' -DLINUXKPI_PARAM_PREFIX=i915_ -DDRM_SYSCTL_PARAM_PREFIX=_i915kms -I$KF "$@" -c "$src" -o $X/obj-i915/$(basename "${src%.c}").o
