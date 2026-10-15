#!/bin/bash
# gen_ccdb.sh: writes a compile_commands.json entry for every bsdcompat/src file so clangd/pi-lens
# analyze with the port's real include paths (same flags as ccsrc.sh, without the -o compile step).
X=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$X/.." && pwd)
K=$R/kpi; D=$K/drm-kmod; A=$D/drivers/gpu/drm/amd; L=$K/freebsd-src/sys/compat/linuxkpi
FLAGS="-arch x86_64 -mmacosx-version-min=15.0 -mkernel -fapple-kext -nostdinc -std=gnu11
  -include $R/Raphaeli/Compat/include/nmxkpi_prelude.h
  -include $L/common/include/linux/compiler.h -include $L/common/include/linux/kconfig.h -include $R/Raphaeli/Compat/include/nmxkpi_post.h
  -I$R/Raphaeli/Override/include -I$R/Raphaeli/Compat/include -I$D/linuxkpi/bsd/include -I$L/common/include -I$L/dummy/include
  -I$D/include -I$D/include/drm -I$D/include/uapi -I$D/drivers/gpu/drm -I$D/drivers/gpu -I$D/drivers
  -I$A/amdgpu -I$A/include -I$A/include/asic_reg -I$A/acp/include -I$A/pm/inc -I$A/pm/swsmu/inc -I$A/pm/swsmu
  -I$A/pm/powerplay/inc -I$A/pm/legacy-dpm -I$A/amdxcp -I$A/display -I$A/display/include -I$A/display/modules/inc -I$A/display/dc -I$A/display/amdgpu_dm -I$A/amdkfd
  $(sed "s/^/ /" $X/amd.flags | tr "\n" " ") -I$R -I$K/freebsd-src/sys"
python3 - "$R" "$FLAGS" <<'EOF'
import json, sys, glob, pathlib, shlex
root = sys.argv[1]
flags = shlex.split(sys.argv[2].replace("\n", " "))
entries = []
for f in sorted(glob.glob(root + "/Raphaeli/Compat/src/*.c")):
    entries.append({"directory": root, "file": f, "arguments": ["/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"] + flags + ["-c", f]})
# the IOKit glue (xnu/*.cpp): ccxx.sh's flags — Apple's Kernel.framework headers, the nmxxnu boundary
# includes, no FreeBSD tree. Without these clangd/pi-lens fall back to a header-less parse.
import os
sdk = os.popen("xcrun --sdk macosx --show-sdk-path").read().strip()
KF = sdk + "/System/Library/Frameworks/Kernel.framework/Headers"
xnuflags = ["-arch", "x86_64", "-mmacosx-version-min=15.0", "-mkernel", "-fapple-kext", "-nostdinc",
            "-isysroot", sdk, "-I", KF, "-I" + root + "/Raphaeli/Compat/include/nmxxnu",
            "-DKERNEL", "-DKERNEL_PRIVATE", "-DDRIVER_PRIVATE", "-DAPPLE", "-DNeXT",
            "-std=c++17", "-fno-rtti", "-fno-exceptions", "-fno-builtin", "-fno-common", "-O2",
            "-Wall", "-Wno-unused-parameter", "-Wno-deprecated-declarations", "-Wno-inconsistent-missing-override"]
for f in sorted(glob.glob(root + "/Raphaeli/Kernel/*.cpp")):
    entries.append({"directory": root, "file": f, "arguments": ["/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++"] + xnuflags + ["-c", f]})
pathlib.Path(root + "/compile_commands.json").write_text(json.dumps(entries, indent=1))
print("entries:", len(entries))
EOF
