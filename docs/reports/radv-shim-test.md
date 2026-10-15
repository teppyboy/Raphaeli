# RADV on drm-shim (macOS, no kext, no GPU) — end-to-end validation

Date: 2026-10-15. Result: **PHYSICAL DEVICE ENUMERATION SUCCESS**; compute submit accepted, execution is a noop (as upstream).

## 1. Shim targets

`ninja -C build-darwin -t targets | grep shim` was initially **empty** — the lane's configure line used `-Dtools=` (empty), so no drm-shim targets were generated. Change (build config only, no source edits, no `research/` touched):

```
cd /Users/yuuki/Documents/tretrauit/code/Raphaeli/work-mesa
PKG_CONFIG_PATH=/Users/yuuki/Documents/tretrauit/code/Raphaeli/out/usr/lib/pkgconfig \
meson configure build-darwin -Dtools=drm-shim
ninja -C build-darwin src/amd/drm-shim/libamdgpu_noop_drm_shim.dylib
```

Built: `build-darwin/src/drm-shim/libdrm_shim.a` (core, compiled `drm_shim_darwin.c` from mesa-macos.patch) and `build-darwin/src/amd/drm-shim/libamdgpu_noop_drm_shim.dylib` (amdgpu ioctl handlers + `amdgpu_devices.c` chip DB). Linker warning "ignoring duplicate libraries: -lSystem -lz" (benign, pre-existing).

The shim DB contains the target chip: `amdgpu_devices.c` entry `name="phoenix"`, `.radeon_family = CHIP_PHOENIX`, `.dev.device_id = 0x15bf`, family `AMDGPU_FAMILY_GC_11_0_1`, gfx11 hw_ip (ip_discovery_version 0xb0001). Selected via `AMDGPU_GPU_ID=phoenix` (shim default is "renoir").

## 2. Shim invocation

No Vulkan loader exists on the host (no vulkaninfo, no libvulkan), so a tiny ICD-direct client was used: `/tmp/radv-shim/probe.c` (~250 lines C, no build-tree code) `dlopen`s the installed ICD and resolves everything through `vk_icdGetInstanceProcAddr` / `vkGetDeviceProcAddr` (VK_ICD v2 entrypoint `_vk_icdGetInstanceProcAddr` is exported by `libvulkan_radeon.dylib`).

```
DYLD_INSERT_LIBRARIES=/Users/yuuki/Documents/tretrauit/code/Raphaeli/work-mesa/build-darwin/src/amd/drm-shim/libamdgpu_noop_drm_shim.dylib \
AMDGPU_GPU_ID=phoenix \
VK_ICD_FILENAMES=/Users/yuuki/Documents/tretrauit/code/Raphaeli/out/usr/share/vulkan/icd.d/radeon_icd.x86_64.json \
/tmp/radv-shim/probe /tmp/radv-shim/add.spv
```

Shader: `/tmp/radv-shim/add.comp` (`values[gid] = 42 + gid`, storage buffer), compiled with brew glslangValidator 16.6.0 → `add.spv`.

Proof the darwin shim was actually interposed: `/dev/dri` does not exist on this host (`ls /dev/dri` → No such file or directory), yet with `DRM_SHIM_DEBUG=1` the shim prints `Initializing DRM shim on /dev/dri/renderD128` and RADV opens the fake node through the dyld `__DATA,__interpose` hooks in `drm_shim_darwin.c`.

## 3. Physical device output (verbatim)

```
vkEnumeratePhysicalDevices -> 0, count=1
PhysicalDevice[0]: name="AMD Radeon Graphics (RADV PHOENIX)" vendorID=0x1002 deviceID=0x15bf apiVersion=1.4.363 driverVersion=26.2.99 driverID-free(raw=0x6802063)
  queueFamily[0]: count=1 flags=0x1f tsBits=0x40 minImgTransferGran=1x1x1
  queueFamily[1]: count=4 flags=0xe tsBits=0x40 minImgTransferGran=1x1x1
  queueFamily[2]: count=1 flags=0x8 tsBits=0x0 minImgTransferGran=1x1x1
```

flags 0x1f = GRAPHICS|COMPUTE|TRANSFER|SPARSE|OPTICALFLOW (gfx ring), 0xe = compute x4 (MEC), 0x8 = transfer (DMA). Device ID 0x15bf = Phoenix/gfx1103. RADV reports API 1.4.363, driverVersion 26.2.99 (raw 0x6802063). Host-visible memory types present: mask 0x1c07c of 17.

## 4. How far execution got (compute path)

Full client-side Vulkan path succeeded on the shim:

1. vkCreateInstance (1.3 requested), device enumeration — OK
2. vkCreateDevice with compute queue — OK
3. vkCreateShaderModule + vkCreateComputePipelines — OK (full **ACO shader compilation** ran on CPU; gfx1103 pipeline built)
4. Buffer alloc (shim GEM_CREATE/GEM_MMAP → malloc-backed BO), map host-visible — OK
5. Command buffer record: bind pipeline, bind descriptor set, `vkCmdDispatch(4,1,1)` — OK
6. vkQueueSubmit → shim `DRM_AMDGPU_CS` handler → **0 (success)**
7. vkWaitForFences → shim `DRM_AMDGPU_WAIT_FENCES` noop → 0, returns immediately signaled
8. Buffer after dispatch: `0 0 0 0` — **NOT written**

Conclusion: `amdgpu_noop_drm_shim.c` handles `DRM_AMDGPU_CS` with `amdgpu_ioctl_noop` (returns 0, discards the IB). Same semantics as upstream ("its 41-chip test is a noop"): everything up to and including IB submission is validated; nothing executes, no results are produced. There is no softpipe/emulated backing in the noop shim — that class of shim (e.g. freedreno's) doesn't exist for amdgpu upstream either. So a compute *result check* is impossible by design on this shim; reaching step 8 with success codes is the maximum reachable depth.

## 5. Blockers / residual notes

- None blocking the noop-shim goals. The two `No such file or directory` lines printed at startup come from libdrm probing the missing real `/dev/dri` before the shim answers; harmless.
- Known shim identity quirk (upstream code, not ours): `drm_shim_driver_init` sets the PCI identity used by `drmGetDevices2` to 0x1002:0x15E7 while the chip DB / dev-info device_id is 0x15bf; RADV keys off AMDGPU_INFO_DEV_INFO, so it correctly reports PHOENIX. If a future consumer keys off the PCI ID it will see renoir's 0x15E7.
- Compute result verification would need a real driver stack (kext) or a Mesa-side emulator; out of scope.

## 6. Changes logged

- `work-mesa/build-darwin`: reconfigured `-Dtools=drm-shim`; built shim targets. No source files added/modified; `git status` in work-mesa shows only the pre-existing `mesa-macos.patch` files (11 modified + 1 added by the patch). `research/` untouched.
- New (outside trees): `/tmp/radv-shim/{probe.c,add.comp,add.spv,probe}` — test client only.
