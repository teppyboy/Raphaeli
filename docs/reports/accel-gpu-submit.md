# Accel lane A — real GPU submit beyond the page-table REFUSED line

Status: **blocked, no code change.** The bridge already runs a real ring submit. The step past
`commitIntoGPUPageTable` REFUSED needs (a) a GPU VM bind path and (b) a decoder for the
IOAccel command stream. Neither is in tree, and (b) needs hardware evidence.

## What already exists (verified in source)

- `nmx_accel_bridge_submit` (Override/src/nmx_accel_bridge.c): `amdgpu_ib_schedule(gfx_ring, 1, &ib, NULL, &f)`
  with `job == NULL`, i.e. the ring-test shape. The IB is the caller's GPU address. No VM, no job.
- `nmx_accel_bridge_fence_wait`: `dma_fence_wait_timeout`, errors propagated (accel_fence_test.py covers it).
- `nmx_accel_bridge_alloc/dmap/free`: pinned VRAM/GTT BO, real device address (`RaphaeliVidMemory`).
- `RaphaeliMemoryMap::commitIntoGPUPageTable` returns false (Kernel/nmx_accel_uc.cpp). Family then refuses
  the submit at the VA-map step, so nothing reaches `nmx_xnu_accel_ring_submit` from a client.

## Why the submit cannot be wired honestly now

1. **No GPU VM bind.** `commitIntoGPUPageTable` needs `amdgpu_vm_bo_map` on a per-client
   `struct amdgpu_vm` (init via `amdgpu_vm_init`, `amdgpu_vm_make_compute` or the gfx VM path, plus
   `amdgpu_vm_update_range`/`amdgpu_vm_clear_freed` and a VMID flush through a job). The bridge's
   `ib_addr` is currently an unchecked raw address; a client-supplied VA would reach the ring unmapped.
   That is the wrong-GPU-address fault the AGENTS.md no-panic rule forbids.
2. **IB decode is unknown.** `IOAccelCommandQueue::submit_command_buffers` is family code. The token walk
   (`processDataBuffers`) hands command streams to the vendor context. Their layout (`IOAccelCommandStreamInfo`,
   descriptor offsets, the AMD `ati_token_process_methods` equivalents) is not reconstructed. Guessing it
   violates "do not guess private IOAccel selectors" and is the decision recorded in accel-protocol.md §4.
3. **No hardware.** Phoenix gfx1103 ring/VM behavior is unverified on this host. Selftest
   `raphaeli-accel-test=1` is still hardware-gated.

## Patch plan (next lane, in order)

1. Bridge: `nmx_accel_bridge_vm_*` wrapping a per-task `amdgpu_vm` (init/destroy on `createTask`/task free),
   `map(bo, va, size)` → `amdgpu_vm_bo_map` + `amdgpu_vm_update_range`, `unmap` → `amdgpu_vm_bo_unmap`.
   Gate on `adev->accel_working`, `in_suspend`, `shutdown`; return errno, never panic. Host test: mock VM ops,
   assert unmapped VA rejected before submit.
2. `commitIntoGPUPageTable` / `updateGPUPageTable` / `releaseFromGPUPageTable` call the bridge; keep REFUSED on
   any bridge errno.
3. Submit: pass a VA-validated IB (`ib_addr` must lie in a mapped range of the caller's VM) and a real
   `amdgpu_job`/VMID so `amdgpu_vm_flush` runs. Only then does `nmx_xnu_accel_ring_submit` see client work.
4. IOAccel decode: reconstruct `IOAccelCommandStreamInfo` from the 15.7.8 family binary, and the AMD token
   processing for the gfx NOP/PACKET3 subset only. Unknown tokens → `kIOReturnUnsupported`.
5. Hardware gate: selftest on target Phoenix, then WindowServer open.

## Validation run

- `python3 scripts/tests/accel_fence_test.py`: PASS (rc 0), fence/selftest bodies, timeout/error
  propagation, in-flight IB retention. No source changed, so no re-build was run.
- No edits to Raphaeli/Kernel, Raphaeli/Override, or any other tracked file. Other uncommitted changes
  (README.md, scripts/build.sh, scripts/package.sh, scripts/rt.sh, build-all files) left untouched.
- Nothing staged, committed, or pushed.

## Residual risks

- Recommended: do not enable any client-reachable submit until steps 1–2 exist; the current
  `nmx_xnu_accel_ring_submit` takes a raw GPU address with no VM check and is reachable only via the
  boot-arg selftest.
