# Accel VM-aware submit gate

Status: **blocked.** Sequoia KDK evidence proves that `IOAccelTask::free()` performs family-owned cleanup before entering its superclass free chain. It does not provide a safe point for whole-task amdgpu VM teardown after map cleanup but before object deallocation, so production VM provisioning remains fail-closed.

## Exact ABI evidence

Evidence binary: `/Library/Developer/KDKs/KDK_15.7.8_24G824.kdk/System/Library/Extensions/IOAcceleratorFamily2.kext/Contents/MacOS/IOAcceleratorFamily2`.
The evidence was obtained with `nm -arch x86_64 -n` and by parsing the binary's
`__DATA,__const` section. This is exact Sequoia KDK 15.7.8 x86_64 evidence only;
it does not establish compatibility with another family build or arm64e.

`nm -arch x86_64 -n` reports:

- `__ZN11IOAccelTask4freeEv` at `0x393f0`;
- `__ZTV11IOAccelTask` at `0x7a9b8`;
- `__ZNK11IOAccelTask7releaseEv` at `0x39534`.

The `__DATA,__const` section has address `0x6a3e0`. Parsing it at offset
`435168` finds the `free()` pointer `0x393f0` at file/VM address `0x7aa58`.
The pointer is symbol-relative byte offset `0xa0` from `0x7a9b8`, or raw qword
index 20. After the ABI's two header words, the conventional vtable slot index
is 18. These conventions must not be conflated: the unambiguous evidence is
pointer location `0x7aa58`, target `0x393f0`, symbol-relative byte offset
`0xa0`, raw qword index 20, and conventional slot index 18.

The same KDK `IOAccelMemoryMap` vtable dump (`research/nvidia-macos-driver/tools/vtdump.py`)
shows base methods `allocGPUVirtualAddress` at method index 42 and
`freeGPUVirtualAddress` at method index 44, followed by three pure-virtual
slots at indices 46–48. Here vtdump method indices count virtual functions
from the first function entry (the destructor); the `+0x160` virtual call
therefore targets method index 44. This is `freeGPUVirtualAddress`, not
`releaseFromGPUPageTable` and not the map destructor.

`IOAccelTask::free` at `0x393f0` iterates its first memory-map list at task
`+0x1e8` and dispatches each map's virtual slot `+0x160`. The KDK vtable dump
identifies that displacement as `freeGPUVirtualAddress` (vtdump method index 44;
`allocGPUVirtualAddress` is index 42), not a PTE-release or map-free hook. It
then iterates a second list at task `+0x200`, invokes virtual slot `+0x28` on
each element, and clears 25 pointer
fields in the task (`qword` indices
`0x2d` through `0x3c`). It removes the task from `IOAccelTaskList` at
`0x39511`, then calls `*0xa0(%rax)` at `0x39520`, which is `OSObject::release`.
The release symbol at `0x39534` first calls virtual slot `*0x18(%rax)` (the
retain/release count operation); when that reports the last reference, it
performs family mapping cleanup and eventually calls virtual task `free` via
`*0x18(%rax)` near `0x39690`. The `IOAccelMemoryMap::free` symbol at `0x529bc`
removes itself from its backing memory map list, releases the task reference
stored at map `+0x18`, frees dynamic allocation storage if present, then tail-
dispatches virtual slot `*0xa0(%rax)` at `0x52a5c`.

This gives evidence that the family task-free implementation performs its
tracked-map operations before entering the superclass free chain. A subclass
`free()` override would run before the base cleanup; calling the base free then
returning to destroy the VM is unsafe because that chain owns object deallocation.
The ABI evidence therefore shows no post-map/pre-deallocation extension point.
The base's virtual call at
`0x39487` is slot `+0x160` of `IOAccelMemoryMap`, which the vtable dump
identifies as `freeGPUVirtualAddress` (method index 44; `allocGPUVirtualAddress`
is index 42), **not** the distinct `releaseFromGPUPageTable` virtual. In the
orphaned-task release branch, the same
slot is called after `release_pte`/`finishEvent`. The map destructor later
removes the map from its backing `IOAccelMemory`, performs IOKit range cleanup,
and dispatches its OSObject free chain. This distinction is important: VM PTE
release belongs to the separately reconstructed `releaseFromGPUPageTable`
contract, and must not be inferred from `freeGPUVirtualAddress` alone.

The evidence does **not** prove every vendor-map override's ordering, that all
external/asynchronous jobs have retired, or that `amdgpu_vm_fini` is safe
relative to device reset/detach. `RaphaeliTask::free()` would execute before the
base map callbacks. Calling the base free before returning from an override
would enter the object deallocation chain, so no safe post-base callback is
available either. This disassembly therefore **does not provide a safe whole-VM
destruction point** and does not authorize adding the override. The inherited
`IOAccelTask::init` path's
`callq *0x20(%rax)` is the OSObject retain slot documented in
`docs/reports/accel-protocol.md`.

## Current source contract

Source evidence paths:
`Raphaeli/Kernel/nmx_accel.h` and `Raphaeli/Kernel/nmx_accel_uc.cpp` define
`RaphaeliTask` as the empty subclass containing only
`OSDeclareDefaultStructors(RaphaeliTask)`. It has no `free` override, destructor,
or task-owned VM field. The bridge evidence is
`Raphaeli/Override/src/nmx_accel_bridge.c`.

The current behavior:

- `nmx_accel_bridge_vm_create` applies device gates, then calls `amdgpu_vm_init`
  with the open path's XCP value and registers the VM record;
- `nmx_accel_bridge_vm_map` and `nmx_accel_bridge_vm_unmap` validate device,
  handle, and ranges, then record the BO range in a bridge-owned `bo_va` table
  under drm_exec PD and BO locks (`amdgpu_vm_bo_add`/`_map`/`_unmap`/`_del`);
  a failed PDE update rolls the mapping back, and a mapped BO cannot be freed;
- `nmx_accel_bridge_client_submit` validates device, VM, ring, and IB shape,
  zeroes an optional fence output, then returns `-ENOTSUP` without creating an
  amdgpu job or fence;
- `RaphaeliMemoryMap::commitIntoGPUPageTable` and
  `RaphaeliMemoryMap::updateGPUPageTable` remain fail-closed;
- no IOAccel client selector is wired to submit, and unknown selectors remain
  `kIOReturnUnsupported`.

The internal ring selftest remains distinct: its `amdgpu_ib_schedule` path uses
`job == NULL` and is not a client submission contract.

## Remaining blocks before safe VM provisioning

The proven virtual `free()` does not resolve these lifetime and ABI questions:

1. **Only part of family mapping-cleanup ordering is proven.** The KDK's
   `IOAccelTask::free` iterates tracked maps and calls their virtual free slots
   before releasing the task's final reference. But it does not prove vendor
   map override behavior, outstanding GPU work completion, all map ownership,
   or allocator/BO ordering for an amdgpu task VM.
2. **amdgpu device lifetime synchronization is unknown.** A task cleanup path
   must not call `amdgpu_vm_fini` after device detach, reset teardown, or bridge
   shutdown.
3. **PASID allocation and delayed release are unproven.** The task VM may require
   a PASID, and its delayed release must be synchronized with family and amdgpu
   lifetimes.
4. **XCP selection is unproven.** `amdgpu_vm_init` needs the correct XCP context;
   selecting one by assumption can bind a task to the wrong execution partition.
5. **Outstanding map/job/fence cleanup is unproven.** BO, VM, scheduler entity,
   job, and fence ownership must survive completion, reset, and final task
   release without a use-after-free or leaked in-flight submission.
6. **Family-vs-bridge teardown ordering is unproven.** The bridge must not tear
   down task VM state while family cleanup or delayed releases can still use it.

Until these are verified, do not add a `RaphaeliTask::free()` override or replace
client-submit `-ENOTSUP` with `amdgpu_job_alloc`/`amdgpu_job_submit`.

## Static contract test

`scripts/tests/accel_task_lifetime_test.py` checks report evidence tokens and
source state; it does not parse the ABI binary. The exact ABI evidence was
independently captured from the local KDK and is recorded here. The test checks
that `RaphaeliTask` has no free override; client submit retains its fail-closed
`-ENOTSUP` path; map and unmap reach the `bo_va` table; and the report identifies the binary, section,
addresses, offset/index conventions, virtual teardown, and every remaining
lifetime block.
`scripts/tests/accel_vm_lifecycle_test.py` remains the host contract for the
fail-closed VM bridge and verifies device gates, create refusal, invalid handles,
range checks, and the absence of amdgpu VM calls. These are static/host tests,
not hardware validation.

## Pinned amdgpu lifecycle evidence (source scout)

The lifecycle test reads the exact pinned sources under `kpi/drm-kmod` and
asserts the following sequence:

- `amdgpu_driver_open_kms` in `amdgpu_kms.c` allocates a PASID with
  `amdgpu_pasid_alloc(16)`, calls `amdgpu_xcp_open_device`, initializes the VM
  with `amdgpu_vm_init(adev, &fpriv->vm, fpriv->xcp_id)`, and registers it with
  `amdgpu_vm_set_pasid`, in that order. Its current `pasid = 0` fallback after
  allocation failure is explicitly **not adoptable** for the task bridge: zero
  is not a newly allocated task PASID. The lifecycle test pins this exception
  as a constraint rather than endorsing the DRM fallback for task use. The DRM
  open path also routes post-init failures through VM finalization; the VM
  initializer itself has error rollback for delayed state and scheduler/page
  table setup.
- `amdgpu_driver_postclose_kms` saves `fpriv->vm.pasid` and a reference to
  `fpriv->vm.root.bo`, runs `amdgpu_vm_fini`, then calls
  `amdgpu_pasid_free_delayed(pd->tbo.base.resv, pasid)` against the root BO's
  reservation before releasing the BO.
- `amdgpu_vm_init` initializes scheduler entities and creates the root page-table
  BO through `amdgpu_vm_pt_create`, passing its `xcp_id` argument through.
  `amdgpu_vm_fini` clears the PASID mapping, frees the root page table, and
  destroys scheduler entities. VM manager teardown warns unless the PASID xarray
  is empty (`WARN_ON(!xa_empty(&adev->vm_manager.pasids))`).
- `amdgpu_xcp_open_device` returns early without an XCP manager; otherwise it
  initializes `AMDGPU_XCP_NO_PARTITION`, resolves a matching render minor,
  rejects an invalid partition, and maps the selected ID into `vm.mem_id`. The
  no-partition sentinel remains distinct from XCP 0. A future task VM must prove
  its partition policy rather than assume the DRM call's result or copy the
  UMSCH selftest's `-1`.
- Device teardown sets `adev->shutdown = true` in `amdgpu_device_fini_hw`, and
  `amdgpu_device_fini_sw` finishes IP teardown before setting
  `adev->accel_working = false`. These are device gates, not task lifetime
  proof.

The UMSCH selftest in `amdgpu_umsch_mm.c` is not a task model. It allocates its
own `test->vm`, calls `amdgpu_vm_init(adev, test->vm, -1)`, allocates a PASID
separately, and later directly frees that PASID and VM. It does not call
`amdgpu_vm_set_pasid`, does not use `amdgpu_fpriv`, and therefore does not prove
that a task VM can be registered or torn down through the DRM task lifecycle.
The test pins these negative facts as well as the positive source sequence.

This appendix does not change the gate: `IOAccelTask::free` evidence remains
real but insufficient, and the bridge remains fail-closed until family cleanup
ordering, device synchronization, PASID ownership, and outstanding work
lifetime are proven.
