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

## 6. Repo-side status (Lane B, 2026-10-17): exact missing layers

No ObjC plugin was built. Reason: the only Metal runtime in-tree (`deps/metal2vulkan`, pinned
submodule, read-only here) is pure Rust with no C ABI (no `#[no_mangle]`, no `cdylib`/`staticlib`),
so an ObjC `MTLCreateSystemDefaultDevice` shim cannot call it without a new FFI crate, which is an
unapproved design decision. Nothing faked.

Missing layers, in order from app to GPU:

1. **Metal plugin binding** (`Raphaeli/Metal/`, absent): an ObjC bundle implementing the
   `MetalPluginClassName` device class, backed by a C ABI over metal2vulkan-runtime (new crate
   needed; decision pending).
2. **Plugin registration** (`Raphaeli/Kernel/nmx_accel.cpp`, `Raphaeli/Info.plist`): `RaphaeliAccel`
   publishes no `MetalPluginName` / `MetalPluginClassName` / `IOGLBundleName`. Reference:
   `research/nvidia-macos-driver/kexts/NVRM/accel/nmx/Info.plist` lines 37-38.
3. **Vendor discovery** (userspace): read `vendor-id` from the parent of the accelerator IOService
   (reference: `nvmtl_vk.c:64-115`) to pick RADV for 0x1002.
4. **GPU device nodes**: `/dev/dri` absent on this host. Needs NMXGPU attach (`raphaeli-amd=1`),
   hardware-gated on the Phoenix target.
5. **RADV ICD on this host**: `out/usr/share/vulkan/icd.d/radeon_icd.x86_64.json` exists, but
   `out/usr/lib/radeon_icd.x86_64.json` (build.sh target) does not; `install_name` points at `out/`.
   Smoke through RADV fails with `VkResultCode(-3)` (no GPUs), as before.

Verified this pass: lavapipe smoke (`VK_DRIVER_FILES=work-metalplugin/icd/lvp_icd.x86_64.json`,
run from `work-metalplugin/smoke/`) prints `SMOKE TEST PASS`.

Preflight: `scripts/metal-preflight.sh` reports each layer as ready/BLOCKED (exit 2 when blocked),
test `scripts/metal-preflight.test.sh` (fixture roots). Current host: 4 layers blocked.

## 7. Lane 2 (2026-10-17): C ABI scaffold, no backend

Survey: `deps/metal2vulkan` (pinned submodule, read-only) has no C ABI. `grep` for `no_mangle`,
`crate-type`, `cdylib`, `staticlib` finds nothing in `crates/`. `metal2vulkan-runtime` is `[lib]`
rlib only, and its `extern "C"` uses are Objective-C runtime imports, not exports. So a real Rust FFI
boundary cannot be built without changing the pinned submodule, which is out of scope.

Shipped instead (no acceleration claimed):

- `Raphaeli/Metal/nmx_metal_shim.h` / `.c`: C ABI seam. `nmx_metal_backend_available()` returns 0;
  `nmx_metal_create_device()` returns `NMX_METAL_UNSUPPORTED` with `*device_out = NULL`.
- `scripts/tests/nmx_metal_shim_test.c` + `scripts/metal-shim.test.sh`: builds the shim with
  `clang -std=c11 -Wall -Wextra -Werror` and asserts the unsupported contract. 4 checks, all pass.
- `scripts/metal-preflight.sh` unchanged: `metal-plugin-objc` stays BLOCKED (the shim is C, not the
  ObjC `.m` plugin the check looks for). Current host: 4 layers blocked, rc=2.

Not done (needs decisions): a Rust `cdylib` over metal2vulkan-runtime, which requires a change to the
pinned submodule or a new crate; the ObjC `MTLCreateSystemDefaultDevice` bundle; plugin registration in
`Info.plist`. No Metal support is claimed: nothing has executed a GPU dispatch through this shim.

## 8. Lane 3 (2026-10-17): plugin ABI and registration contract, still absent

Re-checked against pinned `deps/metal2vulkan` (720ef1ce) and current tree: no change, nothing shipped.

Missing contract, exactly what a Metal plugin needs before acceleration can be advertised:

1. **Runtime C ABI**: `deps/metal2vulkan` exports no `#[no_mangle]` symbols and declares no `cdylib`/`staticlib`
   (`extern "C"` hits are Objective-C/creation-log imports only). Required: a new FFI crate or an approved
   submodule change exposing device create/destroy, buffer, library, and dispatch entry points.
2. **Plugin binding**: no `Raphaeli/Metal/*.m` ObjC class (`MetalPluginClassName`) implementing the
   device interface. `nmx_metal_shim.{h,c}` is a C seam that always returns `NMX_METAL_UNSUPPORTED`; it is
   not a plugin and does not satisfy `metal-plugin-objc`.
3. **Registration**: `Raphaeli/Info.plist` and `RaphaeliAccel` publish no `MetalPluginName` /
   `MetalPluginClassName`. Reference shape (NVIDIA, not copied): `research/nvidia-macos-driver/kexts/NVRM/accel/nmx/Info.plist:37-38`
   (`MetalPluginName` bundle-relative path, `MetalPluginClassName`). The bundle path and class name for
   Raphaeli are undecided.
4. **Vendor discovery**: userspace read of `vendor-id` from the accelerator's parent (reference
   `nvmtl_vk.c:64-115`); no ABI chosen.

Preflight guard: `scripts/metal-preflight.test.sh` now asserts that a provisioned plugin source without a
`MetalPluginName` registration keeps `metal-plugin-registration` BLOCKED (rc=2). Caveat: the check is a
key-presence grep, so a plist containing the key in a comment would read ready; it proves nothing about a
loadable plugin.

## 9. Lane 4 (2026-10-21, Task 6 of gpu-acceleration plan): blocked, gate added

Status: blocked. Gate test: `scripts/tests/metal_plugin_gate_test.py` (static, host-only). No runtime
backend, no ObjC plugin, no registration: `Raphaeli/Metal/nmx_metal_shim.{h,c}` stays
`NMX_METAL_UNSUPPORTED` and nothing here claims acceleration.

Re-verified at pin `deps/metal2vulkan` 720ef1ce:

- `#[no_mangle]`: 0 hits in all `*.rs`. `extern "C"` hits are Objective-C runtime imports, dyld
  callbacks, creation-log imports, and test fixtures, not exports.
- `crate-type`: not declared. `deps/metal2vulkan/crates/metal2vulkan-runtime/Cargo.toml` `[lib]` is
  `name = "metal2vulkan_runtime"`, `path = "src/lib.rs"`, with the default rlib type; no `cdylib`/`staticlib`.
- `Raphaeli/Info.plist`: no `MetalPluginName`, `MetalPluginClassName`, or `IOGLBundleName`.
- `Raphaeli/Metal/`: no `*.m` plugin source.

Missing symbols and contracts, exactly (none may be claimed until each exists):

1. Runtime C ABI: a versioned wrapper crate (or an approved submodule change) that exports device
   create/destroy, resource lifetime, AIR/metallib library creation, pipeline/encoder/dispatch,
   synchronization, and status translation. Decision on wrapper vs. submodule change is not made
   (plan §6 step 1 requires it be recorded).
2. ObjC plugin under `Raphaeli/Metal/*.m` implementing the `MetalPluginClassName` device class over (1).
3. Registration in `Raphaeli/Info.plist`: `MetalPluginName` and `MetalPluginClassName` (plus any bundle
   key), added only after the ObjC bundle loads (plan §6 step 5).
4. Vendor discovery: `IOObjectConformsTo` + parent `vendor-id` == `0x1002` (userspace only).

Host gate (`python3 scripts/tests/metal_plugin_gate_test.py`) fails if any item above appears without
the contract, and checks that the shim still reports unsupported and makes no dlopen/Vulkan/Metal calls.
It also asserts this report names the gate and `Status: blocked`. It does not prove loadability.

Live `scripts/metal-preflight.sh`: rc=2, 4 layers BLOCKED (radv-icd-manifest, gpu-device-nodes,
metal-plugin-objc, metal-plugin-registration).
