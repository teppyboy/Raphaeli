# Acceleration gap: VM-aware task ownership, mapping, job submission

Status: **gap open. Client GPU VM and submit remain disabled (fail-closed).** This report is the implementation contract for the next lane. No kernel source changed in this lane.

Supersedes the gap summary in `accel-vm-gate.md` and `accel-gpu-submit.md` where they differ. Those remain as history.

## Authoritative current state (verified in source, 2026-10 tree)

Linux target evidence in `docs/reports/linux-780m-bringup.md` identifies a real
Radeon 780M as HawkPoint1 PCI `1002:1900`, with Linux amdgpu, RADV and radeonsi
working. Its supplied log reports gfx_v11_0_0, while this tree's historical
firmware census is for Phoenix GC 11.0.1. The report does not contain the full
IP-discovery table or active firmware identities, so it neither proves nor
rules out compatibility. Existing `1002:15bf` assumptions require reconciliation;
do not expand product matching until exact ID/IP/firmware coverage is established.

| Area | File | State |
|---|---|---|
| Ring submit | `Raphaeli/Override/src/nmx_accel_bridge.c:78` `nmx_accel_bridge_submit` | `amdgpu_ib_schedule(gring, 1, &ib, NULL, &f)`: `job == NULL`, `vm == NULL`, raw caller `ib_addr`. No VM, no job, no VMID. |
| Fence wait | `nmx_accel_bridge.c:168` | `dma_fence_wait_timeout`, errors propagated. |
| BO alloc/dmap/free | `nmx_accel_bridge.c:114/144/152` | Pinned kernel GEM BO, VRAM/GTT, stable device address. Free order: reserve, kunmap, unpin, unreserve, unref. |
| Task VM | none | No `struct amdgpu_vm` per IOAccel task. `RaphaeliAccel::createTask` / `fRanges` (`Kernel/nmx_accel.h`) is VA range accounting only, no amdgpu VM. |
| Memory map commit | `Kernel/nmx_accel_uc.cpp:67` `commitIntoGPUPageTable` | `return false` with log. Refuses. |
| Memory map update | `nmx_accel_uc.cpp:74` `updateGPUPageTable` | `return false`. |
| Memory map release | `nmx_accel_uc.cpp:73` `releaseFromGPUPageTable` | empty; no-op. |
| Client submit selector | none | No IOAccel selector reaches `nmx_xnu_accel_ring_submit`. Only `raphaeli-accel-test=1` selftest does. |
| IB decode | none | `IOAccelCommandQueue` token walk / `IOAccelCommandStreamInfo` not reconstructed. |
| Static guard | `scripts/tests/accel_vm_gate_test.py` | PASS. Checks commit/update fail-closed, no client call to raw submit, BO free order, `amdgpu_job_alloc` signature. |
| Fence guard | `scripts/tests/accel_fence_test.py` | PASS. |

Net: **zero** per-task GPU VM, **zero** BO-to-VA mapping, **zero** amdgpu job for client work. The raw submit path is kernel selftest only and must stay that way until the contract below is met.

## Pinned APIs (`kpi/drm-kmod/drivers/gpu/drm/amd/amdgpu/`)

Only these names and signatures are approved for the bridge. Anything else requires a new decision.

VM lifecycle (`amdgpu_vm.h:494-497`):
- `int amdgpu_vm_init(struct amdgpu_device *adev, struct amdgpu_vm *vm, int32_t xcp_id);`
- `int amdgpu_vm_make_compute(struct amdgpu_device *adev, struct amdgpu_vm *vm);`
- `void amdgpu_vm_release_compute(...)`, `void amdgpu_vm_fini(struct amdgpu_device *adev, struct amdgpu_vm *vm);`
- Upstream reference: `amdgpu_kms.c:1340` (init, DRM file open) and `:1381/:1445` (fini, error and close paths). Tied to DRM file lifetime; use the same init/fini pairing, not the file lifetime.

BO to VM mapping (`amdgpu_vm.h:521-556`):
- `struct amdgpu_bo_va *amdgpu_vm_bo_add(struct amdgpu_device *adev, struct amdgpu_vm *vm, struct amdgpu_bo *bo);`
- `int amdgpu_vm_bo_map(adev, bo_va, uint64_t addr, uint64_t offset, uint64_t size, uint64_t flags);`
- `int amdgpu_vm_bo_unmap(adev, bo_va, uint64_t addr);`
- `int amdgpu_vm_bo_clear_mappings(adev, vm, ...)`, `amdgpu_vm_bo_del`, `amdgpu_vm_bo_lookup_mapping`.
- `int amdgpu_vm_update_range(adev, vm, immediate, unlocked, flush_tlb, allow_override, sync, start, last, flags, offset, vram_base, ...)` (full signature at `:521`; read before use).
- `int amdgpu_vm_clear_freed(adev, vm, struct dma_fence **fence);` (`:509`)
- `int amdgpu_vm_update_pdes(adev, vm, bool immediate);` (`:507`)
- `int amdgpu_vm_validate(...)`, `amdgpu_vm_ready(vm)`, `amdgpu_vm_generation(adev, vm)`.

Job and scheduling (`amdgpu_job.h:47,91-104`, `amdgpu_ring.h:466`):
- `int amdgpu_job_alloc(struct amdgpu_device *adev, struct amdgpu_vm *vm, struct drm_sched_entity *entity, void *owner, unsigned int num_ibs, struct amdgpu_job **job);`
- `struct dma_fence *amdgpu_job_submit(struct amdgpu_job *job);`
- `int amdgpu_job_submit_direct(job, ring, &fence);`
- `int amdgpu_vm_flush(struct amdgpu_ring *ring, struct amdgpu_job *job, bool need_pipe_sync);` (`amdgpu_vm.h:506`)
- Scheduler entity: `drm_sched_entity_init(entity, priority, sched_list, num_sched_list, guilty)` (`include/drm/gpu_scheduler.h:614`), as in `amdgpu_gfx.c:1415`.
- `amdgpu_ib_schedule` with `job == NULL` is kernel-internal ring test only. Do not reuse for client work.

## Implementation contract

### C1. Task VM ownership

- One `struct amdgpu_vm` per accelerator task, owned by the task object (`RaphaeliTask` / its `IOAccelTask` owner), not global and not per-device.
- Create at task creation via `amdgpu_vm_init(adev, vm, xcp_id)`. Failure returns errno; the task is not created.
- Destroy at task free via `amdgpu_vm_fini`. Destruction must run after all jobs and BO mappings owned by the task are complete or reset-cleaned (C4).
- Bridge names (internal, C ABI, declared in `Raphaeli/Compat/include/nmx_port.h` next to `nmx_accel_bridge_submit`): `nmx_accel_bridge_vm_create(uint64_t *vm_out)` / `nmx_accel_bridge_vm_destroy(uint64_t vm)`. Opaque handle is `struct amdgpu_vm *` cast to `uint64_t`, same as the existing BO handle convention.
- Gate every entry on `adev->accel_working`, `in_suspend`, `shutdown` (same gates as `nmx_accel_bridge_submit`). Return errno; never panic.

### C2. BO to VA mapping

- Bridge: `nmx_accel_bridge_vm_map(vm, bo, va, offset, size, flags)` = `amdgpu_vm_bo_add` (once per task/BO pair) then `amdgpu_vm_bo_map`, then `amdgpu_vm_update_range` + `amdgpu_vm_clear_freed` as the flush sequence.
- Bridge: `nmx_accel_bridge_vm_unmap(vm, bo, va, size)` = `amdgpu_vm_bo_unmap` followed by the same update/clear sequence.
- Reject before any amdgpu call: `va + size` overflow, `size == 0`, `va` not in task VA range (`fRanges`), `bo` not owned by this task VM, suspended/shutdown device, teardown in progress.
- `updateGPUPageTable` / `releaseFromGPUPageTable` call these. Any errno keeps `commitIntoGPUPageTable` returning `false` (REFUSED).

### C3. Job submission

- Client submit is: caller IB at `ib_addr` must lie wholly inside a range mapped in the caller's task VM (C2). Otherwise reject with errno. No raw address reaches `amdgpu_ib_schedule`.
- Build job: `amdgpu_job_alloc(adev, task_vm, entity, owner, 1, &job)` with a per-task or per-ring `drm_sched_entity` (`drm_sched_entity_init` on `&ring->sched`). Fill `job->ibs[0]` with the validated IB. Establish VMID/PD state first (`amdgpu_vm_update_pdes`, `amdgpu_vm_validate`/`amdgpu_vm_ready`), then `amdgpu_vm_flush(ring, job, need_pipe_sync)` runs before schedule.
- Submit with `amdgpu_job_submit(job)` and return its fence. Wait via the existing `nmx_accel_bridge_fence_wait`.
- The kernel-only `nmx_accel_bridge_submit` stays unchanged for `raphaeli-accel-test=1`. The client path is a new function; no selector calls the old one.

### C4. Ownership and teardown

- Retain BO, `amdgpu_bo_va`, VM, job, and fence until the fence signals or a reset cleanup runs.
- On failed fence wait (timeout), keep the in-flight IB and job retained (existing behavior from `accel-fence-timeout.md`). Do not free on timeout.
- Free order: unmap all task VA, `clear_freed`, then BO `free` (existing reserve, kunmap, unpin, unreserve, unref order), then `amdgpu_vm_fini`.

### C5. Fail-closed gate until C1-C3 land

- `commitIntoGPUPageTable` returns `false`; `updateGPUPageTable` returns `false`.
- No IOAccel selector wired to submit. Unknown selectors remain `kIOReturnUnsupported`.
- `scripts/tests/accel_vm_gate_test.py` must still pass until the lane that replaces it updates it deliberately.

## No-guess ABI rule

- Use only symbols and struct fields that appear in the pinned `kpi/drm-kmod` headers listed above, and in the reconstructed family headers under `research/nvidia-macos-driver/.../accel/`.
- Do not guess IOAccel private selectors, `IOAccelCommandStreamInfo` layout, descriptor offsets, token formats, or AMD PACKET3 encodings. If a value is not in a pinned header or a reconstructed header, stop and escalate; do not infer it.
- Do not guess `amdgpu_vm_update_range` argument meaning. Read the pinned declaration and its implementation before calling.
- Do not change `kpi/` or `deps/`. Pinned trees only.
- Bridge C ABI (`nmx_accel_bridge_*`) is internal to this project; its signatures are chosen here and may change, but must match between `Override/src/nmx_accel_bridge.c` and the `nmx_port.h` declarations.
- Handles crossing the boundary are opaque. The kernel side never dereferences them.

## Acceptance tests (to add with the implementation lane)

Static (python, extends `accel_vm_gate_test.py` style):
1. `commitIntoGPUPageTable` / `updateGPUPageTable` return `false` until bridge map exists; grep check.
2. No IOAccel path calls `nmx_accel_bridge_submit` (raw) or any new client submit with an unvalidated `ib_addr`.
3. `amdgpu_job_alloc` signature matches pinned `amdgpu_job.h:91-93`.
4. Bridge VM create/destroy and map/unmap each check `accel_working`, `in_suspend`, `shutdown` before any amdgpu call.
5. Free path order: unmap, `clear_freed`, BO reserve/kunmap/unpin/unreserve/unref, `amdgpu_vm_fini`.

Host unit (C++ `clang++ -std=c++17`, mock amdgpu symbols, same pattern as `scripts/tests/nmx_fb_edid_test.cpp`):
6. Unmapped VA rejected before any `amdgpu_job_alloc`.
7. Overflow `va + size` rejected.
8. IB outside caller VM range rejected.
9. Map failure leaves no BO/VM retained; errno returned.
10. Timeout on fence wait keeps job and IB retained.
11. Teardown with live mappings unmaps before `amdgpu_vm_fini`.

Hardware (mark unverified on dev host, do not fake): VM map on gfx1103 ring, VMID flush, selftest with `raphaeli-accel-test=1`, WindowServer open.

## Residual risks

- `amdgpu_vm_init` vs `amdgpu_vm_make_compute`: upstream DRM uses `amdgpu_vm_init` in `amdgpu_kms.c`. Compute path (KFD) not in scope. Choosing init-only is a decision for the implementation lane to confirm.
- Single shared `drm_sched_entity` per task vs per ring is not decided here. Escalate before implementing.
- VMID/PD establishment order on Phoenix (gfx11 IP discovery) is unverified on hardware.
- Client-reachable submit must not ship until C1-C4 and hardware gate pass.

## Validation run (this lane)

- `python3 scripts/tests/accel_vm_gate_test.py`: PASS (rc 0).
- `python3 scripts/tests/accel_fence_test.py`: PASS (rc 0).
- No kernel source edited. Only this file written.
- Nothing staged, committed, or pushed.
