# Vendored source references

Fetched locally for the AMDGPU/RADV bring-up investigation. These are source dependencies, not proof of macOS support. Revisions recorded from this checkout:

| Source | Repository | Revision | Notes |
|---|---|---|---|
| Mesa (userspace build pin) | https://gitlab.freedesktop.org/mesa/mesa.git | `d44453ce07ba5e1e6b71f7960809c38f2526c1cd` | git submodule `deps/mesa` (full clone) + `patches/mesa-macos.patch`; builds out/usr/lib RADV dylibs. |
| Mesa (GPU-port reference pin) | https://gitlab.freedesktop.org/mesa/mesa.git | `bffd91947efc1932da99aca69fc540d6d4201b0c` | vendored at `research/nvidia-macos-driver/gpu-port/mesa/`; sparse parent repo worktree. |
| libdrm (userspace build pin) | https://gitlab.freedesktop.org/mesa/drm.git | `b97cbde15c5c3abfe44d78e8f57139e50f612fec` | git submodule `deps/libdrm` (full clone) + `patches/libdrm-macos.patch`; builds out/usr/lib libdrm dylibs. |
| libdrm (GPU-port reference pin) | same repo, vendored at `research/nvidia-macos-driver/gpu-port/libdrm/`. ||
| metal2vulkan (translation layer) | https://github.com/steelbrain/metal2vulkan.git | `720ef1ce9ae2a2068999a8675717418b9416283e` | git submodule `deps/metal2vulkan`; consumed by work-metalplugin (Rust path deps) and the Metal plugin lane. |
| drm-kmod | https://github.com/freebsd/drm-kmod.git | `c16de0f9fa84f70b9551f69fde837a7f3a73c0e9` | master at fetch time; contains AMDGPU/DRM source, GPL components must be audited file-by-file. |
| FreeBSD src | https://github.com/freebsd/freebsd-src.git | `f4fe4c3d17f9bb523981b88a01d7c0f0c0f00c36` | `main` (git submodule kpi/freebsd-src); LinuxKPI rebased per docs/reports/linuxkpi-rebase.md. |
| macOS AMD port prototype | https://github.com/raphaeli/nvidia-macos-driver.git | `cd8e2bb04da48d2fa70cf1895879608f3588dbfb` | `gpu-port/`; local reference only. Its build assumes an existing `/Volumes/MiniData/build/gpu-src` source layout and has not been hardware-tested. |

The GPU-port pins match the vendored worktrees. The FreeBSD source revision is provisional: its headers do not match the compiler_types.h path assumed by the copied scripts, so build compatibility must be resolved before treating this source set as a usable build.
