# GPU acceleration implementation plan

**Date:** 2026-10-21
**Status:** plan only; no implementation, commit, or push in this task
**Scope:** move the current IOAccelerator path from fail-closed VM/map stubs to a narrowly testable VM-aware client-submit path, then provide a Metal/plugin path only after the kernel and ABI gates pass.

## 1. Contract and non-negotiable boundary

The current state is deliberately safe but incomplete: `nmx_accel_bridge_submit()` uses `amdgpu_ib_schedule(..., job = NULL, vm = NULL)` for the `raphaeli-accel-test=1` kernel selftest only; `RaphaeliMemoryMap::{commitIntoGPUPageTable,updateGPUPageTable}` refuse; there is no client selector-to-submit path; and the Metal C shim is unsupported. This plan does not turn the raw ring-test hook into a client API.

Client submit is enabled only in an explicit **test mode**, gated by a new boot argument named `raphaeli-accel-client-test=1`, and only when the normal `raphaeli-amd=1` opt-in and all validation gates below succeed. It is off by default, is not added by OpenCore `--add`, is not added by packaging/install, and must not be advertised as production acceleration. Without the client-test argument, all existing client map/submit behavior remains fail-closed. `raphaeli-accel-test=1` remains the separate kernel NOP selftest.

The test mode must refuse to arm unless all of these are true:

- the attached device is the verified Phoenix target (`0x1002:0x15bf`, gfx1103 path and matching firmware census);
- the device is `accel_working`, not suspended, not shutting down, and not in teardown/reset cleanup;
- the pinned amdgpu VM/job declarations and their implementations have been re-read and match the bridge calls;
- the exact IOAccel family ABI for the running OS build has been verified; and
- host tests, static safety tests, build/link checks, and the target hardware selftest have passed.

Any failed gate returns an error/unsupported result and leaves client submission disabled. There is no unrestricted fallback to a raw GPU address, guessed packet, guessed selector, or fake success.

## 2. Files and interfaces to change

### Kernel/IOKit side

- `Raphaeli/Kernel/nmx_accel.h`
  - Keep the Apple-only boundary: no amdgpu includes.
  - Add the task-owned opaque VM/job state to the vendor task carrier only if the verified `IOAccelTask` lifetime hooks permit it; otherwise retain a side table keyed by the exact task object, with teardown synchronization.
  - Add declarations for the new VM-aware C wrappers and the client-test gate.
  - Include only reconstructed IOAccel headers whose class sizes/vtable slots are verified for the target build. Do not add speculative private declarations.
- `Raphaeli/Kernel/nmx_accel.cpp`
  - Keep `nmx_xnu_accel_ring_submit()` as the kernel selftest wrapper and never call it from client work.
  - Add the client-submit wrapper that passes a task VM handle and a validated IB to the bridge, mapping negative errno to the appropriate IOKit result.
  - Implement the boot-arg gate and log explicit armed/refused state without exposing a normal-production path.
- `Raphaeli/Kernel/nmx_accel_uc.cpp`
  - Replace `RaphaeliMemoryMap` refusal only after the bridge and task lifetime tests pass.
  - Route `commitIntoGPUPageTable`, `updateGPUPageTable`, and `releaseFromGPUPageTable` to the task VM/BO map records; any bridge error remains a false/refused result.
  - Add the verified context/token decode hook only in a class method whose declaration and vtable slot are proven from the exact IOAcceleratorFamily2 ABI. Unknown tokens, command types, and malformed buffers return the family’s unsupported/error result and do not submit.
  - Preserve current resource and surface refusal behavior until each corresponding GPU contract is implemented and tested.
- `Raphaeli/Kernel/nmx_accel_decode.h` and `Raphaeli/Kernel/nmx_accel_decode.cpp` (new, if keeping decode separate improves reviewability)
  - Hold bounds-checked parsing of the verified `IOAccelCommandStreamInfo`, data-buffer descriptors, resource references, and the deliberately small supported command subset.
  - Expose a plain result such as `{status, ib_gpu_va, ib_dw, referenced_resources}`; do not expose amdgpu types.
  - The decoder must prove every IB address/length is inside a mapped task range before returning success. Unknown or unsupported commands return an error, never a partially decoded IB.
  - If ABI reconstruction cannot prove the field offsets and token encodings, do not create this file or wire the hook; leave the existing fail-closed path and record the blocker.
- `Raphaeli/Kernel/nmx_kext.cpp`
  - Keep attach opt-in and RecoveryOS attach behavior unchanged.
  - Continue invoking the kernel selftest only when `raphaeli-accel-test=1` is present. Do not invoke client submission from attach and do not add a RecoveryOS opt-out.
  - Ensure bridge/device teardown is ordered after client tasks/jobs have stopped or been reset-cleaned.

### C bridge and shared declarations

- `Raphaeli/Override/src/nmx_accel_bridge.c`
  - Add task VM lifecycle, BO-to-VM map/unmap bookkeeping, VM flush/update, scheduler entity, VM-aware job construction, and reset-safe ownership.
  - Keep `nmx_accel_bridge_submit()` unchanged in semantics: it is kernel selftest infrastructure only.
  - Add a distinct client API; proposed internal shape:
    - `int nmx_accel_bridge_vm_create(uint64_t *vm_out);`
    - `int nmx_accel_bridge_vm_destroy(uint64_t vm);`
    - `int nmx_accel_bridge_vm_map(uint64_t vm, uint64_t bo, uint64_t va, uint64_t offset, uint64_t size, uint64_t flags);`
    - `int nmx_accel_bridge_vm_unmap(uint64_t vm, uint64_t bo, uint64_t va, uint64_t size);`
    - `int nmx_accel_bridge_client_submit(uint64_t vm, uint32_t ring, uint64_t ib_addr, uint32_t ib_dw, uint64_t *fence_out);`
  - These are internal C ABI names, not public user APIs. The final signatures must match both declarations exactly and the pinned headers/implementation calls.
  - Gate every entry before any amdgpu call on device presence, `adev->accel_working`, `!in_suspend`, `!shutdown`, and non-teardown state.
  - Validate zero sizes, page alignment requirements, all additions/subtractions for overflow, task VA-range membership, BO ownership in the VM, ring bounds, scheduler readiness, and complete IB containment before touching amdgpu.
  - Do not cast or dereference an untrusted handle. Opaque handles are checked against bridge-owned records before use.
- `Raphaeli/Compat/include/nmx_port.h` and `Raphaeli/Compat/include/nmxxnu/nmx_port.h`
  - Keep the duplicate shared-header declarations synchronized (or replace them only if the existing include/build convention proves one is generated from the other).
  - Document that the raw submit is selftest-only and the client function is VM-aware, mapped-range-checked, and test-mode-gated.
  - Add no public ioctl or ABI: the bridge remains internal to the kext.

### Build and test seams

- `scripts/rt.sh`: include any new Kernel/Override source through the existing globs and update the expected source count only with the corresponding source addition; retain the 81/81 gate after implementation.
- `scripts/link.sh`: add any new explicit `xnuobj/nmx_accel_decode.o` (or equivalent) object to the kext link list; do not rely on an accidental glob. Preserve `-source_version`, embedded firmware symbol checks, and existing ownership guidance.
- `scripts/tests/accel_vm_gate_test.py`: evolve the current fail-closed assertions into the implementation contract: raw submit remains selftest-only, the new client function requires a VM/job, all bridge gates precede amdgpu calls, and cleanup order is preserved.
- Add a focused host test, preferably `scripts/tests/accel_vm_submit_test.py` or a C++ mock harness matching the existing `clang++ -std=c++17` style, for validation and ownership without kernel execution.
- Add an ABI/decode test fixture only from captured, verified Sequoia/Tahoe command data; no synthetic layout may be presented as ABI proof.
- `scripts/metal-preflight.sh` and `scripts/metal-preflight.test.sh`: keep Metal blocked until a real ObjC plugin, runtime backend, registration, RADV ICD, and GPU nodes all exist. Add a check that client-test mode is not enabled by install/preflight defaults.
- `scripts/package.sh`, package tests, install tests, and OpenCore tests: package the test-mode documentation/diagnostics if needed, but never inject `raphaeli-accel-client-test=1` automatically.

## 3. TDD implementation sequence

Each phase must add/adjust its test before the implementation change, then run the narrow test and the source gate before proceeding.

### Phase A — preserve the safety baseline

1. Extend `accel_vm_gate_test.py` to assert:
   - `nmx_accel_bridge_submit` still contains the pinned `job == NULL` kernel selftest shape;
   - no IOAccel method calls the raw submit wrapper;
   - client-test mode is absent unless the explicit boot argument is parsed;
   - `commitIntoGPUPageTable` and `updateGPUPageTable` remain refusal paths until VM map support is complete;
   - both shared `nmx_port.h` copies agree on declarations.
2. Add tests for boot-arg combinations: no AMD opt-in, AMD only, client-test only, both, wrong device identity, suspended device, and failed validation. Only the final combination can arm.
3. Run the existing fence test and all relevant host tests before touching bridge behavior.

### Phase B — per-task VM lifecycle

1. Add mocked VM lifecycle tests: create success, create failure, device-gate refusal, double destroy, destroy during teardown, and task creation rollback.
2. In `RaphaeliAccel::createTask`, create exactly one VM for the task after the family task initialization contract is proven. The VM is not global and not per device. The task owns the opaque handle and a teardown flag.
3. Call only the pinned APIs from `amdgpu_vm.h`: `amdgpu_vm_init(adev, vm, xcp_id)` with the selected xcp contract confirmed from the implementation, and `amdgpu_vm_fini` after all task mappings/jobs are gone. Do not call `amdgpu_vm_make_compute` unless a source review proves this IOAccel task needs the compute lifecycle; do not silently choose between the two.
4. If the family frees the task through a base implementation with no verified override slot, use a bridge-owned task record and an explicit final-release path tied to the verified task object lifetime. A VM that cannot be destroyed at the exact task lifetime is a blocker, not a reason to leak or make it global.
5. Tests must prove failed `amdgpu_vm_init` leaves no task visible to the family and no retained VM handle.

### Phase C — BO and VM mapping

1. Add mock tests for overflow, zero length, misalignment, VA outside `fRanges`, wrong-task BO, duplicate map, unmap of an unknown mapping, suspended/shutdown device, and map failure rollback.
2. Track each task/BO pair and its `amdgpu_bo_va` in bridge-owned records. Retain the BO for the mapping; never infer ownership from a raw GPU address.
3. Implement map as: validate all inputs; locate/create the one `amdgpu_bo_va` for the task/BO pair; call `amdgpu_vm_bo_map` with the verified offset/size/flags; perform the required update/flush sequence from the pinned `amdgpu_vm_update_range` declaration and implementation; update PDEs/clear freed state as required by that implementation. Every error unwinds the just-created mapping and leaves no partially owned record.
4. Implement unmap as: validate exact task/BO/VA/size; call `amdgpu_vm_bo_unmap`; run the same verified page-table update/clear sequence; remove the bridge record only after successful cleanup.
5. Wire `commitIntoGPUPageTable`, `updateGPUPageTable`, and `releaseFromGPUPageTable` to these operations. A false return is required for every missing task/BO/VA association or bridge error.
6. Add a teardown test proving unmap all mappings, clear freed state, and only then free BOs and call `amdgpu_vm_fini`.

### Phase D — VM-aware job submission

1. Add host tests before the bridge submit implementation:
   - unmapped VA is rejected before `amdgpu_job_alloc`;
   - `va + ib_dw * 4` overflow is rejected;
   - IB crossing a mapped range is rejected;
   - wrong VM/BO/ring is rejected;
   - device suspend/shutdown/reset gates reject without amdgpu calls;
   - the pinned `amdgpu_job_alloc(adev, vm, entity, owner, 1, &job)` argument order is used;
   - job allocation, VM flush, schedule, and fence error unwind retain/free each object exactly once.
2. Select the scheduler entity only after reviewing the pinned scheduler implementation and escalating any unresolved choice between one entity per task and one per ring. The plan’s default is one entity per task/ring pairing if the family can serialize it; otherwise one per task with a verified ring list. Do not invent a scheduler lifetime.
3. Initialize the entity with the pinned `drm_sched_entity_init(entity, priority, sched_list, num_sched_list, guilty)` contract and destroy it only after all jobs have completed or reset cleanup has retired them.
4. Build a job with the task VM, entity, owner, and one IB. Establish VM/PDE/VMID state using the verified `amdgpu_vm_update_pdes`, `amdgpu_vm_validate`/`amdgpu_vm_ready`, and `amdgpu_vm_flush` sequence. The exact `amdgpu_vm_update_range` and flush ordering must follow the pinned implementation, not this prose if the source differs.
5. Populate `job->ibs[0]` only with the decoder’s mapped-range-validated IB. Submit through `amdgpu_job_submit` (or the explicitly verified direct variant) and return the fence through the existing wait bridge. Never route client work through `amdgpu_ib_schedule` with a NULL job.
6. Preserve timeout behavior: a failed wait does not free the in-flight IB, job, BO, mapping, or VM. Add reset cleanup that retires or marks these records only after the driver confirms completion/cancellation. Until that cleanup exists, the client-test gate remains disarmed.

### Phase E — verified IOAccel decode and client path

1. First collect and freeze ABI evidence for each supported OS build: exact `IOAcceleratorFamily2` binary, reconstructed headers, vtable slot map, class sizes, selector table, `IOAccelCommandStreamInfo`/descriptor field offsets, and representative command buffers from a controlled target run. Record hashes/build numbers in a report; do not infer from names or a different OS.
2. Verify the family call chain from `IOAccelCommandQueue::submit_command_buffers` through `IOAccelContext2::{processDataBuffers,beginCommandStream,endCommandStream,bindResource}` and the vendor override slot that can safely reject/submit. There is no assumed vendor “queue submit selector.”
3. Add only the smallest command subset whose token format, resource references, packet encoding, and bounds are all proven. The first supported subset should be a test command that can be validated against the target’s gfx11 packet definition; it must not accept arbitrary AMD PACKET3 values merely because they fit in a buffer.
4. Decoder rules:
   - validate descriptor/data-buffer lengths before every read;
   - reject unknown token kinds and unsupported resource access modes with `kIOReturnUnsupported` or the family’s verified submission error;
   - resolve resources to the caller’s task VM, not a global address;
   - validate IB alignment, dword count, mapped range, and packet bounds;
   - reject malformed or cross-resource references before any bridge call;
   - return no partial job on any error.
5. Add fixture tests for valid minimum command, truncated descriptor, unknown token, integer overflow, unmapped resource, IB outside mapping, and unsupported packet. Add a static test proving no decoder path calls the raw selftest wrapper.
6. Wire the verified family method only under `raphaeli-accel-client-test=1`. Without the flag, preserve current open/config behavior but refuse resource/submit execution honestly. Unknown selectors remain `kIOReturnUnsupported`; no custom selector switch may broaden family dispatch.

## 4. VM/BO/job/fence lifecycle

The lifetime graph is:

```text
IOAccel task
  └─ bridge task record + one amdgpu_vm + scheduler entity/entities
       ├─ BO records (retained amdgpu_bo)
       │    └─ amdgpu_bo_va + mapped VA interval
       └─ in-flight jobs
            ├─ validated IB reference
            └─ dma_fence reference
```

Creation order: device gate → task record → VM init → scheduler entity → family task becomes visible. A failure destroys in reverse order and returns task creation failure.

Map order: task/VM gate → validate VA range and overflow → retain/verify BO ownership → add/find `bo_va` → map → update page tables → publish mapping record. Any failed step unwinds the unpublished state.

Submit order: client-test gate → task/VM/job gate → decode → validate mapped IB and resources → validate/update VM/PDE/VMID state → allocate job → populate IB → submit → retain fence/job/BO/mapping references. The returned fence is opaque; the IOKit side never dereferences it.

Completion order: fence signal/reset cleanup → release job/IB/fence references → release per-submit resource references. A timeout keeps all in-flight state. Task destruction first prevents new work, waits or invokes the verified reset cleanup, unmaps every VA, calls `amdgpu_vm_clear_freed`/required update sequence, releases BOs in the existing order (`reserve`, optional `kunmap`, `unpin`, `unreserve`, `unref`), destroys scheduler entities, and finally calls `amdgpu_vm_fini`.

Device stop/suspend/shutdown sets the bridge teardown gate before removing the device pointer. New VM/map/submit calls fail before amdgpu access. Existing jobs are retained until the pinned driver reset/stop path gives an explicit completion/cancellation result. No timeout path frees GPU-visible memory.

## 5. ABI and OS-version plan

### Sequoia 15.x

- Use the KDK-matched Sequoia `IOAcceleratorFamily2` binary and the existing reconstructed headers as the initial ABI source.
- Re-run symbol import and vtable/class-size checks for the exact target build, not only the dev host’s `15.7.8 (24G824)`.
- Use `kmutil inspect` as a bundle/link sanity check only; it does not prove IOAccel runtime semantics.
- Exercise open/config/event-machine first, then test-mode map/decode/submit with WindowServer disabled or a controlled client where possible.

### Tahoe 26.x

- Treat every Tahoe build as a separate ABI target. The existing audit found matching vtable symbol slots for Sequoia 15.7.8 and Tahoe 26.6 25G72, but it did not prove private ivar offsets, semantics, or later builds.
- Do not copy the research Tahoe forwarding header blindly; it targets a different binary revision. Verify exact family imports, vtables, class sizes, private offsets, and selectors before compiling a Tahoe path.
- Obtain the actual Recovery `SystemVersion.plist` and Boot/System KCs. Do not inject Sequoia graphics-family binaries into Tahoe. If Recovery lacks the superclass binaries required for OpenCore vtable patching, stage only matching-build dependencies through the documented, tested route; never use a mixed collection as a product workaround.
- Run the repository OpenCore injection wrapper with exact dependency binaries before hardware tests. A successful prelink result is necessary but not sufficient for runtime.

## 6. Metal/plugin integration (after kernel gates)

The existing `Raphaeli/Metal/nmx_metal_shim.{h,c}` is intentionally unsupported and must remain so until a real backend exists. The pinned `deps/metal2vulkan` workspace currently provides Rust crates but no exported C ABI (`cdylib`/`staticlib`/`#[no_mangle]` was not found). Do not pretend the C shim is a Metal plugin.

Implementation order:

1. Add a small, versioned C ABI crate/boundary for the required `metal2vulkan-runtime` operations (device create/destroy, resource lifetime, AIR/metallib library creation, pipeline/encoder/dispatch, synchronization, and status/error translation). Do not edit the pinned submodule directly; use an approved wrapper crate or an explicitly approved submodule change, and record the decision.
2. Add the ObjC plugin under `Raphaeli/Metal/` using the reference plugin only as a behavioral template, not as an ABI authority. Implement the minimum `MTLDevice`/queue/resource/library surface supported by the runtime. Every unsupported Metal feature returns the correct failure rather than silently using CPU or a fake device.
3. Discover the accelerator through IOKit userspace only: confirm `IOObjectConformsTo` for the Raphaeli accelerator, walk to the parent `vendor-id`, require `0x1002`, and select the RADV ICD. The plugin does not open an IOAccel private user client directly.
4. Link/load `libvulkan_radeon.dylib` via the packaged ICD manifest and `/dev/dri/renderD*`. Keep a lavapipe path only as a host translator/plugin smoke fallback; never label it GPU acceleration.
5. Add plugin registration (`MetalPluginName`, `MetalPluginClassName`, and any required bundle key) to `Raphaeli/Info.plist` only after the ObjC bundle loads and preflight tests prove registration is real. An armed registration with no loadable plugin is prohibited.
6. Keep WindowServer/presentation separate from headless compute. Do not claim display composition until IOSurface/presentation and RaphaeliFB handoff are separately validated.
7. Add Metal tests for vendor discovery, unavailable `/dev/dri`, RADV selection, AIR-to-SPIR-V translation, unsupported feature reporting, device/resource lifetime, and a real RADV compute/readback smoke. `DeviceOptions::metal_level` escape hatches used for an unmeasured host must be test-only and documented.

## 7. Packaging and installation

- `scripts/build.sh`, `scripts/rt.sh`, and `scripts/link.sh` must remain the only supported build path. Preserve 900/900 kernel sources, 81/81 runtime sources, firmware census from `Raphaeli/Firmware/stage.sh`, embedded firmware symbol checks, `-source_version`, and `kmutil inspect -V tb -p <absolute path>` rc 0.
- `scripts/package.sh` must include only the exact RADV/libdrm dylibs, ICD manifest, firmware, kext, tools, and documentation that are validated. Use existing install/package tests to reject missing ICDs, build-tree dylib paths, stale archives, missing firmware, and invalid bundles.
- Do not add `raphaeli-accel-client-test=1` to `scripts/install.sh`, `scripts/oc-install.py`, `scripts/recovery-install.sh`, package install text, or OpenCore defaults. `--add` stays inert; only the existing explicit `--enable` adds `raphaeli-amd=1`.
- If a test operator needs the client mode, document a manual, reversible target-only command and require a diagnostic collection showing the exact build, GPU ID, firmware census, ABI gate, and selftest status. Do not silently mutate NVRAM from packaging.
- RecoveryOS tooling remains Bash 3.2 compatible: no arrays, `coproc`, or newer shell syntax in scripts intended for Recovery. Never run `installer` on the dev host; inspect packages with `pkgutil --payload-files`.
- Kext bundles intended for kmutil are `root:wheel`; use absolute paths. No signing step is added because AMFI/Secure Boot are disabled in the supported development setup.
- Audit licenses for the reconstructed IOAccel headers, drm-kmod/FreeBSD-derived objects, Mesa/libdrm, metal2vulkan, plugin code, and firmware before distribution. Do not ship a blob without provenance, license, and checksum.

## 8. Hardware validation gates

The development host has no Phoenix 780M; no hardware result may be simulated from the RADV noop drm-shim or lavapipe.

Run on a target with an independent recovery/display path and a known-good rollback:

1. Capture APU model, PCI ID/revision, ACPI/SMBIOS, OS build, Recovery build, firmware/BIOS settings, current display owner, and kext/firmware hashes.
2. Boot with `raphaeli-amd=1` only. Confirm safe attach, firmware load, BAR/resource setup, `/dev/dri/renderD*`, `drmGetVersion`, and no unexpected client-submit mode.
3. Run `raphaeli-accel-test=1`; require the gfx ring NOP fence PASS and VRAM BO allocation PASS. Repeat cold boot and warm reboot.
4. Validate VM creation/mapping/unmapping with a controlled test task. Check VMID/PDE flush logs, fence completion, no VM faults, no leaked BOs, and correct teardown.
5. Enable `raphaeli-accel-client-test=1` manually only after steps 1–4 pass. Start with the smallest verified command fixture; require mapped-range rejection tests and a successful fence/readback. No arbitrary app workload yet.
6. Exercise timeout/reset, suspend/resume, repeated task create/free, concurrent maps, device stop, and failed attach. Confirm no panic, ring fault, black screen, or leaked NVRAM guard.
7. Validate WindowServer open/config/event machine separately. It must still return unsupported for unknown selectors and must not be mistaken for successful GPU rendering.
8. After kernel/render stability, validate RADV physical-device discovery, ACO pipeline creation, compute dispatch/readback, and then the Metal plugin. Test Sequoia and each Tahoe build independently.
9. Keep display/modeset/panel light-up as a later gate. Stable render precedes display handoff as required by `docs/DESIGN.md`.

Required evidence per target run: serial/console log, `log show` extract, `ioreg` accelerator tree, `/dev/dri` listing, `vulkaninfo` or equivalent, command/fence result, reset/suspend result, OS/Recovery build, and hashes. Mark unverified items explicitly.

## 9. Rollback and safety

- Default rollback is remove the client-test boot argument first, then remove `raphaeli-amd=1`, disable/remove the kext injection, restore the saved aux KC if used, and reboot. Never leave a failed test mode armed.
- Retain and use `raphaeli-gpu-attaching` as the failed-attach park marker. Do not add a RecoveryOS refusal or another attach environment opt-out.
- Preserve the existing `-amdgpuoff`/boot-guard recovery path and document `nvram -d raphaeli-gpu-attaching` only after the failure is understood and a retry is intentional.
- A client timeout retains GPU-visible resources; reset cleanup is the only release path before fence completion. If reset cleanup cannot prove completion, require reboot rather than freeing memory that the GPU may still read.
- Any ABI mismatch, unknown selector/token, unvalidated GPU address, missing firmware, failed prelink dependency, or unsupported OS build disables client mode and returns unsupported/error. It must never fall through to a raw submit.
- No source change may widen `IOPCIPrimaryMatch` beyond verified IDs. The current validated personality remains Radeon 780M `0x15bf` until firmware/IP discovery coverage for another SKU is proven.

## 10. Review focus and acceptance checklist

Reviewers should focus on:

- proof that no client path reaches `nmx_accel_bridge_submit` or any client submit with an unchecked address;
- every bridge gate occurring before the first amdgpu call;
- exact VM/BO/job/fence ownership and teardown ordering, including reset and timeout paths;
- correct pinned `amdgpu_job_alloc` and scheduler/VM API signatures and implementation ordering;
- ABI evidence for every IOAccel selector, vtable slot, class size, private offset, token, and packet accepted;
- `kIOReturnUnsupported` for unknown selectors/tokens/features;
- boot-arg test-mode gating, exact-device validation, and absence of production/package defaults;
- Sequoia/Tahoe dependency and RecoveryOS injection safety;
- no change to attach-everywhere, no-panic, bash-3.2, firmware-census, ownership, signing, or SKU constraints;
- Metal plugin registration only after a real loadable backend, with lavapipe/shim results clearly separated from hardware results;
- license/provenance and rollback evidence.

Acceptance is not “the kext links.” It requires static tests, host lifecycle tests, 900/900 and 81/81 builds, link and kmutil inspection, package/install tests, ABI/prelink evidence for the exact OS build, and target hardware evidence for VM mapping, test-mode submit, fences, reset, and rollback. Hardware-gated results must be marked unverified when unavailable.

## 11. Plan self-review

Before implementation begins, re-check this plan against the repository and approved design:

- [x] Names current bridge, IOKit, shared-header, build, test, Metal, packaging, and deployment seams.
- [x] Separates the existing kernel selftest from new client submission.
- [x] Makes client submit explicit, boot-arg-gated, exact-device-gated, and fail-closed by default.
- [x] Requires per-task VM ownership, mapped BO/VA validation, VM-aware jobs, fence retention, timeout/reset cleanup, and ordered teardown.
- [x] Treats IOAccel decode as ABI evidence work; it does not guess selectors, layouts, tokens, offsets, or packets.
- [x] Covers Sequoia, Tahoe, RecoveryOS, OpenCore dependencies, packaging, firmware, and rollback.
- [x] Preserves AGENTS.md constraints: attach in Recovery, unknown selectors unsupported, non-panicking failure paths, AMD boot-arg opt-in, Bash 3.2, no signing, root:wheel, verified SKU expansion only, pinned-tree immutability, and hardware honesty.
- [x] Calls out the unresolved scheduler-entity and VM lifecycle choices as verification/escalation gates rather than silently deciding them in code.
- [x] Does not propose editing `kpi/` or `deps/` directly, and does not claim that current shim/lavapipe tests prove GPU execution.

No implementation should start until the ABI evidence, task-free lifetime, scheduler-entity choice, and reset-cleanup ownership are explicitly reviewed and approved.
