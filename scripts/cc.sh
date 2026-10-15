#!/bin/bash
# cc.sh <source.c> [extra flags]: compiles one drm-kmod source for the macOS kernel (x86_64) through the
# FreeBSD-on-xnu layer (bsdcompat) and FreeBSD LinuxKPI. drm-kmod's GPL-only linuxkpi/gplv2 headers are NOT on the path.
GPU_SRC_ROOT=${GPU_SRC_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
X=$GPU_SRC_ROOT
K=$GPU_SRC_ROOT/kpi
L=$K/freebsd-src/sys/compat/linuxkpi
D=$K/drm-kmod
A=$D/drivers/gpu/drm/amd
SDK=$(xcrun --sdk macosx --show-sdk-path)
KF=$SDK/System/Library/Frameworks/Kernel.framework/Headers
src=$1; shift
exec xcrun clang -arch x86_64 -mmacosx-version-min=15.0 -ffile-prefix-map=$GPU_SRC_ROOT=/src -mkernel -fapple-kext -nostdinc -std=gnu11 \
  -fno-builtin -fno-common -fno-strict-aliasing -fms-extensions -O2 -g0 \
  -Wno-pointer-sign -Wno-unused-parameter -Wno-microsoft-anon-tag -ferror-limit=80 \
  -D_KERNEL -DKERNEL -DKERNEL_PRIVATE -DLINUXKPI_VERSION=61400 -DNMXKPI=1 \
  -include $X/Raphaeli/Compat/include/nmxkpi_prelude.h \
  -include $L/common/include/linux/compiler_types.h -include $L/common/include/linux/kconfig.h -include $X/Raphaeli/Compat/include/nmxkpi_post.h \
  -I$X/Raphaeli/Override/include -I$X/Raphaeli/Compat/include -I$D/linuxkpi/bsd/include -I$L/common/include -I$L/dummy/include -I$X/fbroot -I$X/Raphaeli/Override/linux \
  -I$D/include -I$D/include/drm -I$D/include/uapi -I$D/drivers/gpu/drm -I$D/drivers/gpu -I$D/drivers \
  -I$A/amdgpu -I$A/include -I$A/include/asic_reg -I$A/acp/include -I$A/pm/inc -I$A/pm/swsmu/inc -I$A/pm/swsmu/inc/pmfw_if -I$A/pm/swsmu/smu11 -I$A/pm/swsmu \
  -I$A/pm/powerplay/inc -I$A/pm/powerplay/hwmgr -I$A/pm/powerplay/smumgr -I$A/pm/swsmu/smu12 -I$A/pm/swsmu/smu13 -I$A/pm/swsmu/smu14 -I$A/pm/legacy-dpm -I$A/amdxcp -I$A/display -I$A/display/include -I$A/display/modules/inc -I$A/display/dc -I$A/display/dc/inc -I$A/display/dc/inc/hw -I$A/display/dc/hwss -I$A/display/dc/optc -I$A/display/dc/hubbub -I$A/display/dc/clk_mgr -I$A/display/dc/dccg -I$A/display/dc/dio -I$A/display/dc/dpp -I$A/display/dc/dsc -I$A/display/dc/dwb -I$A/display/dc/gpio -I$A/display/dc/hpo -I$A/display/dc/hubp -I$A/display/dc/irq -I$A/display/dc/mmhubbub -I$A/display/dc/mpc -I$A/display/dc/opp -I$A/display/dc/pg -I$A/display/dc/resource -I$A/display/dc/dml2 -I$A/display/dc/dml2/dml21/inc -I$A/display/dc/dml2/dml21/src/inc -I$A/display/dc/dml2/dml21/src/dml2_core -I$A/display/dc/dml2/dml21/src/dml2_dpmm -I$A/display/dc/dml2/dml21/src/dml2_pmo -I$A/display/dc/dml2/dml21/src/dml2_mcg -I$A/display/dc/dml2/dml21/src/dml2_standalone_libraries -I$A/display/dc/dml2/dml21 -I$A/display/dmub/inc -I$A/display/modules/hdcp -I$A/display/amdgpu_dm -I$A/amdkfd \
  $(sed "s/^/ /" $X/scripts/amd.flags | tr "\n" " ") -I$KF -I$K/freebsd-src/sys "$@" -c "$src" -o $X/obj/$(basename "${src%.c}").o
