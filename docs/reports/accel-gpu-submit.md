# Accel lane A — VM-aware client submission

Status: **client submission is disabled and fail-closed.** The VM/map bridge records exist, but the former scheduler-job attempt omitted prerequisites required by the pinned AMDGPU submission path. `nmx_accel_bridge_client_submit()` now validates the bridge-owned VM/mapping and returns `-ENOTSUP`; it does not allocate or queue a job. No IOAccel caller reaches it and no client rendering is proven.

## Pinned-source findings

- `amdgpu_job_alloc()` initializes `job->vm_pd_addr` to `AMDGPU_BO_INVALID_OFFSET` (`amdgpu_job.c`). `amdgpu_cs.c` sets it to `amdgpu_gmc_pd_addr(vm->root.bo)`, updates/validates the VM, and synchronizes `vm->last_update` before submitting.
- `amdgpu_vmid_grab()` assigns VMID/PASID at scheduler preparation only when the VM has been initialized and configured for PASID. The current bridge VM creation only calls `amdgpu_vm_init`; it has no PASID lifecycle.
- The previous bridge used one global scheduler entity. There is no verified task-owned entity/job drain/reset lifecycle, so the entity could outlive or race its device/task.
- Family memory-map hooks `RaphaeliMemoryMap::commitIntoGPUPageTable()` and `updateGPUPageTable()` still refuse. The bridge BO allocations and mapping records are not connected to family-created objects; there is no client IB source.
- The IOAccel command-stream/token layout and vendor submission call path remain unverified. No private selector or packet format is inferred.

## Current safety behavior

- `nmx_accel_bridge_submit()` is the kernel selftest path only and keeps the raw `amdgpu_ib_schedule(..., job=NULL, ...)` shape.
- Client submit checks device state, argument shape, bridge VM identity, and complete mapped-range containment, then returns `-ENOTSUP` before any AMDGPU job API.
- `RaphaeliMemoryMap` remains fail-closed. Unknown family selectors remain unsupported.
- Focused submit, VM lifecycle, VM mapping, BO-free, task-lifetime, and VM-gate tests pass for this fail-closed contract. These host tests do not prove usable GPU page tables, fences, RADV, ABI compatibility, or hardware rendering.

## Required before re-enabling client jobs

Implement per-task VM/PASID ownership and scheduler entity lifetime; follow the pinned VM update and dependency sequence; connect BO and map lifetimes to verified IOAccel objects; provide fence completion/reset cleanup; and obtain exact OS ABI plus Radeon 780M hardware evidence. Until then, do not route client work through raw submit or claim GPU acceleration.
