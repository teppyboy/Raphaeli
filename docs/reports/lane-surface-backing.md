# Surface-backing lane audit

Status: fail-closed. No AMD-specific evidence was found that maps the private
IOAccelerator surface/resource backing layout to an amdgpu GEM/TTM object.

## Scope reviewed

- `Raphaeli/Kernel/nmx_accel.h`
- `Raphaeli/Kernel/nmx_accel_uc.cpp`
- `Raphaeli/Override/src/nmx_accel_bridge.c`
- `Raphaeli/Override/src/nmx_drm_os.c`
- `Raphaeli/Compat/include/nmx_port.h`
- IOAccelerator reconstructed resource, memory, and surface declarations
- existing accelerator fence/source tests and prior accelerator reports

The TTM bridge proves only generic GEM/TTM vmap, mmap pinning, and BO pin/unpin
for DRM mappings. The accelerator bridge proves kernel BO allocation and device
address retrieval. Neither proves the IOAccelerator private resource geometry,
ownership, eviction/page-off lifecycle, or GPU-VA mapping contract for AMD.

## Changes

`RaphaeliResource` now explicitly refuses and sampled-logs `pageoff`, its
extended form, `pageoffIfNeeded`, paging-buffer rebuild, level/backing offsets,
and aperture descriptor access. `RaphaeliSurface::set_shape_backing_length_ext`
logs a refusal instead of accepting an unverified backing description.

`RaphaeliVidMemory::allocPhysical` no longer reads the NVIDIA-derived `+0x40`
length or writes the NVIDIA-derived `+0xc8` physical slot. It returns false and
logs that the AMD GEM/TTM surface contract is unverified. Existing cleanup and
segment access remain guarded, so no speculative BO is exposed to the family.

No NVIDIA offsets were copied into an AMD surface path. Existing generic
amdgpu GEM/TTM bridge code remains unchanged because it cannot answer the
missing private-family contract.

## Tests

- `scripts/tests/surface_backing_test.py`: source assertions prove refusal,
  explicit missing-capability logs, and absence of the NVIDIA-derived allocation
  offsets/call.
- `scripts/tests/accel_fence_test.py`: existing bridge regression test passes.
- Hardware validation remains unavailable on the development host. A target
  test must first establish AMD-family resource length/owner and page-off/VM
  semantics from logs or a verified AMD implementation before enabling backing.

## Validation attempts

`./scripts/rt.sh` and `./scripts/build.sh` could not start because the checked
out worktree lacks the required `research/MacKernelSDK`; the scripts correctly
refuse an active SDK fallback. `ccxx.sh` reports the same missing SDK. No
artifacts were produced by these failed attempts.

## Next evidence required

1. AMD `IOAccelResource`/surface callback or token data showing the backing
   object and exact length/plane layout.
2. A verified amdgpu GEM/TTM pin, eviction, and GPU-VM lifecycle matching those
   callbacks.
3. Hardware selftest covering allocation, page-off, remap, and release before
   changing the refusal paths.
