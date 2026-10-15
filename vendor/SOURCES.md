# Vendored source references

Fetched locally for the AMDGPU/RADV bring-up investigation. These are source dependencies, not proof of macOS support. Revisions recorded from this checkout:

| Source | Repository | Revision | Notes |
|---|---|---|---|
| Mesa (active inspection clone) | https://gitlab.freedesktop.org/mesa/mesa.git | `d44453ce07ba5e1e6b71f7960809c38f2526c1cd` | current-main snapshot at clone time; not the GPU-port build pin. |
| Mesa (GPU-port exact pin) | https://gitlab.freedesktop.org/mesa/mesa.git | `bffd91947efc1932da99aca69fc540d6d4201b0c` | vendored at `research/nvidia-macos-driver/gpu-port/mesa/`; sparse parent repo worktree. |
| libdrm (GPU-port exact pin) | https://gitlab.freedesktop.org/mesa/drm.git | `b97cbde15c5c3abfe44d78e8f57139e50f612fec` | vendored at `research/nvidia-macos-driver/gpu-port/libdrm/`. |
| drm-kmod | https://github.com/freebsd/drm-kmod.git | `c16de0f9fa84f70b9551f69fde837a7f3a73c0e9` | master at fetch time; contains AMDGPU/DRM source, GPL components must be audited file-by-file. |
| FreeBSD src | https://github.com/freebsd/freebsd-src.git | `2b7df8c16dc77a6774a4d309477b1238fe725d93` | `releng/15.0`; sparse checkout of LinuxKPI/CK/kernel headers. Provisional; copied scripts request a missing `compiler_types.h`. |
| macOS AMD port prototype | https://github.com/raphaeli/nvidia-macos-driver.git | `cd8e2bb04da48d2fa70cf1895879608f3588dbfb` | `gpu-port/`; local reference only. Its build assumes an existing `/Volumes/MiniData/build/gpu-src` source layout and has not been hardware-tested. |

The GPU-port pins match the vendored worktrees. The FreeBSD source revision is provisional: its headers do not match the compiler_types.h path assumed by the copied scripts, so build compatibility must be resolved before treating this source set as a usable build.
