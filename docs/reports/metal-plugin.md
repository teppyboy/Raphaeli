# Metal accelerator plugin layer: metal2vulkan-runtime + RADV

Date: 2026-10-15. Lane: Metal plugin integration. All work in `work-metalplugin/` (+ a separate
`work-mesa/build-lvp` build dir); nothing in `research/` touched.

## 1. Survey: how the gpu-port Metal plugin consumes its Vulkan backend

Plugin sources: `research/nvidia-macos-driver/plugin/` (`NVMTL*.m`, `nvmtl_vk.c`), the Metal
framework shim loaded into each Metal process (gated by an allow-list, `NVMTLDevice.m`
`nvmtl_process_is_allowed`).

- **Vulkan loading** (`nvmtl_vk.c:696-727`): the plugin `dlopen`s the **ICD directly** — by vendor,
  `libvulkan_radeon.dylib` / `libvulkan_intel.dylib` / `libvulkan_nouveau.dylib` under
  `/Library/GPUBundles/nvmtl` (`NVMTL_ICD_LIB`), resolving `vk_icdGetInstanceProcAddr` (the ICD
  interface, bypassing a loader). Fallback path: a loader `libvulkan.dylib` +
  `VK_ICD_FILENAMES=<NVMTL_ICD>`. It rebinds `_sysconf`/`_open` in the ICD image for sandboxed
  apps (memory size, owned handles). No IOKit user-client calls from the plugin: it is pure
  userspace over Vulkan.
- **Vendor/accelerator coupling** (userspace only, `nvmtl_vk.c:64-115`): `nvmtl_vk_set_accelerator`
  reads the IOService the Metal device was made on; `IOObjectConformsTo(accel, "NMXAccel")` → parent
  registry entry's `vendor-id` (0x1002 AMD / 0x8086 Intel) picks RADV/ANV; `NVAccel` → NVK. The kext
  side (`kexts/NVRM/accel/nvrm-accel.cpp`, built `-DNMX_ACCEL` = NMXAccel) only provides the
  IOAcceleratorFamily2 accelerator and `nmxgpu-claimed` matching; the plugin never opens a user
  client. Sysctls `debug.nvaccelfb` / `debug.nvaccel_headless` gate WindowServer behavior.
- **Shader path** (`NVMTLLibraryLoad.m`): app-supplied metallib/AIR → optional `air-opt`
  (`/Library/GPUBundles/nvmtl/air-opt`) → their own translator dylib
  (`libnvmtl_translate.dylib`: `nvmtl_translate`, `_lower`, `_link_*`, caches keyed by content
  SHA-256 under `aircache`/`spvcache`) → SPIR-V handed to Vulkan. Optional vendor compiler via
  NVIDIA's `NVIDIAShared` plugin (`NVMTLVendorCompiler.m`, NVIDIA-only).

**Integration decision:** build on **metal2vulkan-runtime** instead of porting `nvmtl_vk.c`'s
7,264-line hand-rolled Vulkan layer. The runtime already implements the Metal object model
(devices/buffers/textures/encoders/hazard tracking), has its own AIR→SPIR-V translation with
per-device profiles and driver-defect tracking, and is exercised by a large validation corpus. The
gpu-port plugin's only parts worth keeping as the design are (a) vendor discovery from the
IOService registry (userspace IOKit read, no user client) and (b) the ICD-by-vendor mapping — both
map to runtime `DeviceOptions` (`loader`, `kinds`) or trivial future glue. AIR entry is
`metal2vulkan::library::Library::from_air` + `Device::new_library_with_compile_library`
(metallib bytes: `new_library_with_data`).

## 2. Stack and wiring (documented decision)

```
Metal app (metallib/AIR)
  → plugin layer (to be built): vendor from NMXAccel IOService vendor-id
  → metal2vulkan-runtime (Metal API on ash/Vulkan; AIR → SPIR-V via metal2vulkan translator,
    device description = real Vulkan physical device caps)
  → Vulkan loader (/usr/local/lib/libvulkan.1.dylib, 1.4.363, already installed; ash "loaded")
  → ICD: RADV libvulkan_radeon.dylib (out/usr/lib, requires NMXGPU kext /dev/dri nodes)
     fallback today: lavapipe CPU ICD (built below) — no kernel dependency
  → libdrm (out/usr/lib) → NMXGPU kext → /dev/dri nodes
```

RADV is selected with `VK_DRIVER_FILES=/…/out/usr/share/vulkan/icd.d/radeon_icd.x86_64.json`.
Device profile: the runtime derives the translation profile from the live physical device; the
Khronos profile `amd-rdna3-radv.json` is used for offline translation (below). For the Phoenix
iGPU target, `amd-780m-radv.json` (exact RADV PHOENIX capture, gfx1103) is the better profile
once real hardware/vulkaninfo is available (see metal2vulkan-build.md §4).

## 3. What builds

- `work-metalplugin/smoke/`: `m2v-smoke` binary (Rust, path-deps on
  `research/metal2vulkan/crates/metal2vulkan{,-runtime}` read-only), `kernel.metal` (Apple metalfe
  unavailable: Xcode Metal toolchain not downloaded), `kernel.ll` in the repo fixture AIR
  convention, assembled to `kernel.air` (magic `dec0 170b`) with brew `llvm-as` 23.1.3
  (`/usr/local/opt/llvm/bin/llvm-as`).
- **lavapipe CPU ICD** (fallback executor): `work-mesa/build-lvp`, fresh meson dir, same mesa tree
  + patch as the RADV build:
  `meson setup build-lvp -Dvulkan-drivers=swrast -Dgallium-drivers=llvmpipe -Dllvm=enabled …`
  (LLVM 23.1.3 via `LLVM_CONFIG=/usr/local/opt/llvm/bin/llvm-config`; brew bison needed —
  `/usr/bin/bison` is 2.3 and fails on the parser sources). One local patch on top of
  mesa-macos.patch: `lp_fence.c` uses `ppoll`, absent on Darwin — replaced with `poll()` ms
  timeout under `#ifdef __APPLE__`. Product:
  `work-mesa/build-lvp/src/gallium/targets/lavapipe/libvulkan_lvp.dylib`; ICD json at
  `work-metalplugin/icd/lvp_icd.x86_64.json`. RADV build (`build-darwin`) untouched.

## 4. Smoke test result (verbatim)

Translator, AIR → SPIR-V with the amd-rdna3-radv profile:

```
$ research/metal2vulkan/target/debug/metal2vulkan work-metalplugin/smoke/kernel.air \
    /tmp/m2v-smoke-lane/kernel.spv \
    --profile crates/metal2vulkan-validation/profiles/amd-rdna3-radv.json --no-spirv-val
metal2vulkan: wrote /tmp/m2v-smoke-lane/kernel.spv; verified: PASS
$ xxd -l 4 /tmp/m2v-smoke-lane/kernel.spv
0302 2307        (SPIR-V magic)
```

RADV ICD through the loader (expected failure, no kext — `/dev/dri` does not exist):

```
$ VK_LOADER_DEBUG=error,warning VK_DRIVER_FILES=…/out/usr/share/vulkan/icd.d/radeon_icd.x86_64.json ./target/debug/m2v-smoke
[Vulkan Loader] ERROR:          setup_loader_term_phys_devs:  Failed to detect any valid GPUs in the current config
Error: Vulkan(VkResultCode(-3))
```

End-to-end on the fallback ICD (loader → lavapipe), full run:

```
$ VK_DRIVER_FILES=/…/work-metalplugin/icd/lvp_icd.x86_64.json ./target/debug/m2v-smoke
metal2vulkan: the device's driver Some(VK_DRIVER_ID_MESA_LLVMPIPE) at driverVersion 0x6802063 on deviceID 0x0 is an identity not measured: … [metal2vulkan-unmeasured-driver]
metal2vulkan: the device, on llvmpipe (LLVM 23.1.3, 256 bits): its driver lists no `VK_KHR_pipeline_binary` … [metal2vulkan-degrade-driver-pipeline-cache-kept]
device: llvmpipe (LLVM 23.1.3, 256 bits)
metal2vulkan: the kernel of a compute pipeline state: its translation records `PrecisionNote::BeyondMeasuredDeviation` … [metal2vulkan-degrade-beyond-measured-deviation]
metal2vulkan: the kernel of a compute pipeline state: its translation records `PrecisionNote::NativeFma` …
metal2vulkan: the kernel of a compute pipeline state: its translation records `PrecisionNote::NativeNanEncoding` …
pipeline: 1024 threads per threadgroup at most, SIMD width 32
metal2vulkan: a dispatch of kernel `scale_offset`: its grid of [1000, 1, 1] threads is not a whole number of threadgroups of [64, 1, 1]; one Vulkan dispatch per region … [metal2vulkan-degrade-split-dispatch]
output[0..4] = [0.0, 3.0, 6.0, 9.0], output[999] = 2997: as expected
SMOKE TEST PASS
```

Verified: device creation through the loader, AIR → SPIR-V translation with the live device's
description, compute pipeline, three Shared buffers, a [1000,1,1] dispatch, host readback matches
`out[i] = in[i]*2 + i = 3i` for all 1000 floats.

Note: `Device::system_default()` refuses this host (`Problem::HostReleaseUnmeasured`, macOS
15.7.8 is below the runtime's measured Metal-level set); the test names
`DeviceOptions::metal_level = Some(MetalLevel::NEWEST)` — the documented escape for unmeasured
hosts/tests. Real-hardware runs must revisit this.

## 5. Remaining gaps to a real Metal.app

1. **RADV execution path**: needs the NMXGPU kext publishing `/dev/dri` (`nmxamd=1`) — then the
   same smoke binary should run unchanged with `VK_DRIVER_FILES` → radeon ICD. drm-shim lane
   (mesa `drm_shim_darwin.c`) can prove RADV device/pipeline creation before the kext lands, but a
   shim cannot execute work, so dispatch/readback needs the kext (or real DRM).
2. **Plugin layer proper** (the Metal framework shim): load metal2vulkan-runtime as the Metal
   device provider in a process, vendor discovery from NMXAccel (`IOObjectConformsTo` +
   parent `vendor-id`), allow-list/WindowServer gating per gpu-port's design; expose
   `MTLCreateSystemDefaultDevice` etc. ObjC surface. The runtime is ObjC-free Rust — needs the
   ObjC shim (the gpu-port `NVMTL*.m` set is the template) or Swift bindings.
3. **Metal toolchain for tests**: Xcode's Metal toolchain is not downloaded
   (`xcrun metal` fails), so `.metal → .air` in-tree used hand-written LLVM IR; download with
   `xcodebuild -downloadComponent MetalToolchain` for real metallib fixtures.
4. **Metal level / driver measurements**: unmeasured-host and unmeasured-driver notices above;
   capture vulkaninfo + recalibrate profile (`amd-780m-radv.json` for Phoenix) on real RADV.
5. **WindowServer/IOSurface presentation** (NMXGPU framebuffer copies) — out of scope here;
   headless compute path is what this lane proved.

## Artifacts

- `work-metalplugin/smoke/` — smoke binary + kernel (`.metal`, `.ll`, `.air`), Cargo project
- `work-metalplugin/icd/lvp_icd.x86_64.json` — lavapipe ICD manifest
- `work-mesa/build-lvp/` — lavapipe build (1 local Darwin patch: `lp_fence.c` ppoll)
- `/tmp/m2v-smoke-lane/kernel.spv` — profile-translated SPIR-V
