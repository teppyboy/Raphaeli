#!/bin/bash
# gen_ccdb.sh: writes a compile_commands.json entry for every bsdcompat/src file so clangd/pi-lens
# analyze with the port's real include paths (same flags as ccsrc.sh, without the -o compile step).
X=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$X/.." && pwd)
K=$R/kpi; D=$K/drm-kmod; A=$D/drivers/gpu/drm/amd; L=$K/freebsd-src/sys/compat/linuxkpi
FLAGS="-arch x86_64 -mmacosx-version-min=15.0 -mkernel -fapple-kext -nostdinc -std=gnu11
  -include $X/bsdcompat/include/nmxkpi_prelude.h
  -include $L/common/include/linux/compiler.h -include $L/common/include/linux/kconfig.h -include $X/bsdcompat/include/nmxkpi_post.h
  -I$X/override/include -I$X/bsdcompat/include -I$D/linuxkpi/bsd/include -I$L/common/include -I$L/dummy/include -I$X/fbroot
  -I$D/include -I$D/include/drm -I$D/include/uapi -I$D/drivers/gpu/drm -I$D/drivers/gpu -I$D/drivers
  -I$A/amdgpu -I$A/include -I$A/include/asic_reg -I$A/acp/include -I$A/pm/inc -I$A/pm/swsmu/inc -I$A/pm/swsmu
  -I$A/pm/powerplay/inc -I$A/pm/legacy-dpm -I$A/amdxcp -I$A/display -I$A/display/include -I$A/display/modules/inc -I$A/display/dc -I$A/display/amdgpu_dm -I$A/amdkfd
  $(sed "s/^/ /" $X/amd.flags | tr "\n" " ") -I$R -I$K/freebsd-src/sys"
python3 - "$R/xkpi" "$FLAGS" <<'EOF'
import json, sys, glob, pathlib, shlex
root = sys.argv[1]
flags = shlex.split(sys.argv[2].replace("\n", " "))
entries = []
for f in sorted(glob.glob(root + "/bsdcompat/src/*.c")):
    entries.append({"directory": root, "file": f, "arguments": ["/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"] + flags + ["-c", f]})
pathlib.Path(root + "/compile_commands.json").write_text(json.dumps(entries, indent=1))
print("entries:", len(entries))
EOF
