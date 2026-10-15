# IOAccelerator protocol lane — the first real WindowServer-facing user client path (v2)

Task: map the open → first-submit protocol on RaphaeliAccel, make the initial WindowServer
handshake work end-to-end at the protocol level (registers, stamps — no real rendering),
route vendor memory allocation to the port's GEM allocator, keep the unknown-selector
`kIOReturnUnsupported` invariant. Study sources: the KDK 15.7.8
`IOAcceleratorFamily2` binary (symbols + disassembly), the shipped AMD driver
(`AMDRadeonX4000.kext`, KDK), the reconstructed family headers
(`research/nvidia-macos-driver/kexts/NVRM/accel/{re,iofam}/`) and the proven reference
lane (`nvrm-accel.cpp`). One direction gap was escalated and decided: **there is no
vendor-side "queue submit selector" to wire** — see §4 — so the submit pass-through is
deferred to the next lane (supervisor-approved, option A).

## 1. What actually happens when WindowServer opens the accelerator

Every user client class is implemented INSIDE IOAcceleratorFamily2 (verified: all
`T`/`S` symbols, no pure vendor virtuals, in the KDK 15.7.8 binary). The vendor nub
(`RaphaeliAccel`, an `IOGraphicsAccelerator2`) only supplies factories, config, memory
and stamps. `IOServiceOpen` → `IOGraphicsAccelerator2::newUserClient` (family) creates
one of five client types; **there is no vendor `initClient`/`getType` callback** — client
init is family-internal (`IOAccelDevice2::init(OSDictionary*, task_t)`,
`IOAccelSharedUserClient2::sharedStart`, `IOAccelCommandQueue::init` …).

**Device plane — `IOAccelDevice2` (392 B, legacy `sDeviceMethods[10]`, dispatch decoded
from `IOAccelDevice2.h` + the binary):** after open, the FIRST external method the system
calls is selector 0, then typically 1/2/7:

| sel | method | convention | what answers it |
|---|---|---|---|
| 0 | `get_config` → `IOAccelDeviceConfigData` (64 B) | ScalarIStructO | family reads our `populateAccelConfig` (real) |
| 1 | `get_name` → 64 B | ScalarIStructO | family (the config's name field, real) |
| 2 | `get_event_machine` → `IOAccelDeviceEventMachineData` (600 B) | ScalarIStructO | family: takes our `getStampMemory` descriptor and **maps the stamp page into the client task itself**, plus the event machine (`RaphaeliEventMachine`) |
| 3 | `get_surface_info` (1 in, 24 out) | ScalarIStructO | family |
| 7 | `get_device_info` → 24 B | ScalarIStructO | family |
| 4–6, 8, 9 | stereo / object id / trace filter / gid group / api property | — | family |
| ≥10 | — | — | family's `getTargetAndMethodForIndex` → NULL → `kIOReturnUnsupported` |

**Resource plane — `IOAccelSharedUserClient2` (360 B, `sSharedMethods[21]`):**
`new_resource` (sel 0) is the memory path: family → `createResource`/`createSysMemory`/
`createVidMemory` factories → `IOAccelVidMemory::allocPhysical` (vendor). With this lane
that call is REAL (§3): one pinned amdgpu GEM BO (VRAM domain 4) via the bridge, device
address in `getPhysicalSegment`. The map side (`IOAccelMemoryMap::commitIntoGPUPageTable`)
still refuses — no page tables yet — so the family unwinds the mapping honestly and the
client sees the v0 line exactly where it is drawn.

**Submit plane — `IOAccelCommandQueue` (family, `sCommandQueueMethods`):** the client
calls `set_notification_port`, `get_command_queue_info`, `set_quality_of_service` and
`submit_command_buffers` (`IOAccelCommandQueueSubmitArgs*`). The queue walks the command
buffer through the CONNECTED context (`IOAccelContext2::processDataBuffers`, token walk,
`bindResource`/`prepareResources`), asking the task for VAs
(`IOAccelTask::allocate` — family default, from the `IORangeAllocator` we hand it) and
committing maps (refuses, v0). A submit therefore **never reaches any engine code in v0**;
it fails at the VM step, which is the documented line.

**Task accounting (what "initClient" really is):** per client the family calls
`createUserGPUTask`/`createKernelGPUTask` → our `createTask` mirrors the proven reference
`newGPUTask`: one `IORangeAllocator` (1<<40, 4096-granular, first 1 MB reserved for
vendor-private descriptors) from a 32-slot pool, then `IOAccelTask::init(this, 1, &slot)`.
The family retains the allocator (verified in `IOAccelTask::init` disassembly:
`callq *0x20(%rax)` = vptr slot 4 = `OSObject::retain`) and runs ALL task bookkeeping from
it — VA allocation (`IOAccelTask::allocate` default: picks `ranges[map->0x78]`, accounts
at task+0xe8), command-buffer-descriptor accounting, `IOAccelTaskList` registration.
`RaphaeliTask` is an empty subclass; nothing vendor-side to override.

## 2. The exact open → first-submit call sequence (v2 state)

```
IOServiceOpen(nub, WindowServer task, type)
└─ IOGraphicsAccelerator2::newUserClient (family) → per-type client
   ├─ IOAccelDevice2:        sel0 get_config  (populateAccelConfig — REAL)
   │                         sel1 get_name,  sel2 get_event_machine
   │                           └─ getStampMemory (REAL 16 KB stamp page) + family maps it into the client task
   │                         sel7 get_device_info, sel3 get_surface_info, …
   ├─ IOAccelSharedUserClient2:
   │    new_resource ─→ createSysMemory/createVidMemory → RaphaeliVidMemory::allocPhysical
   │                         └─ nmx_accel_bridge_alloc (amdgpu_bo_create_kernel, VRAM) — REAL BO
   │    page_off/finish_object/set_purgeable/allocate_fence_memory/get_memory_data … (family + vmem)
   ├─ IOAccelCommandQueue:   set_notification_port, get_command_queue_info
   │    submit_command_buffers → processCommandBuffer → connected context
   │      processDataBuffers: token walk, bindResource, prepareResources
   │        IOAccelMemoryMap::allocGPUVirtualAddress → IOAccelTask::allocate (family, REAL bookkeeping)
   │        IOAccelMemoryMap::commitIntoGPUPageTable → REFUSED (no page tables — v0 line, logged)
   │      ⇒ submit ends honestly before the engine; nothing reaches a ring
   └─ GL/2D/CL/video contexts: our factories return quiet vendor objects (reference shape)
unknown client types / selectors ≥ table end → kIOReturnUnsupported (invariant, unchanged)
```

## 3. Real vs logged

| surface | status |
|---|---|
| `IOServiceOpen` all family client types | real (family) |
| device config/name/event-machine/device-info/surface-info | real (family + our config) |
| stamp page: alloc, `getStampMemory`, client-task mapping (family), `writeStamp` writes | real |
| client-task VA accounting (`IORangeAllocator` pool → family `IOAccelTask`) | real |
| VRAM allocation (`allocPhysical` → bridge `nmx_accel_bridge_alloc/dmap/free`) | real GEM BOs |
| GPU VM (`commitIntoGPUPageTable`/`updateGPUPageTable`) | **refused** — page tables are the next lane |
| queue submit engine path | **never reached in v0** — family fails the submit at the map step |
| fences/syncobj, display pipe, surface swap, Metal plugin | unchanged from v0 (logged/refused) |

Bridge additions (`Override/src/nmx_accel_bridge.c`, declared in `Compat/include/nmx_port.h`):
`nmx_accel_bridge_alloc(size, align, domain, &bo, &gpu_addr, &cpu)` — `amdgpu_bo_create_kernel`,
same device/suspend/shutdown gates as the submit path; `nmx_accel_bridge_dmap(bo)` —
`amdgpu_bo_gpu_offset`; `nmx_accel_bridge_free(bo, gpu_addr, cpu)` — `amdgpu_bo_free_kernel`.
The selftest (`raphaeli-accel-test=1`) now also allocates/frees one 4096 B VRAM BO through
this path and logs PASS/FAIL.

## 4. Where the submit wire-in lands (next lane) — decided

The direction assumed a vendor-visible queue submit selector; the binary says otherwise:
`IOAccelCommandQueue` is 100% family code, and its submit path drives the family's
context token processing. In the real AMD kext the engine submit lives in the vendor's
per-token method tables (`AMDRadeonX4000_AMDSIGLContext` `ati_token_process_methods`, a
`process_*` hook per token) — not one selector. The proven reference lane also leaves
submits vendor-side. A v0 pass-through would require decoding opaque
`IOAccelCommandStreamInfo`/descriptor offsets and handing a guessed GPU address to
`amdgpu_ib_schedule` — a wrong `ib_addr` faults the ring on real silicon, violating the
failure-path-safety invariant. Supervisor decision (A): defer to the next lane, which
must decode `IOAccelCommandStreamInfo` + the AMD token path and THEN wire
`nmx_xnu_accel_ring_submit` (the v1 hook, already real, is the landing surface).

## 5. Validation

- `scripts/ccxx.sh` on both Kernel TUs: clean. `scripts/rt.sh`: 79/79 runtime sources.
- `scripts/link.sh out-disp`: links clean (`Raphaeli 28c12a0e, 10990704 B`), no undefined
  accel symbols.
- `kmutil inspect -V tb -p out-disp/Raphaeli.kext`: exit 0.
- Hardware-gated: selftest `raphaeli-accel-test=1` (IB + VRAM alloc) and a real
  WindowServer open on the target Mac; expected log: `createUserGPUTask -> … (VA
  allocator …, init ok)` then `getStampMemory -> descriptor …`, on allocation
  `vid memory allocPhysical … REAL VRAM - device address 0x…`.

## 6. Residual risks

- The family's client-task stamp mapping and `IOAccelTask` bookkeeping offsets (+0x78,
  +0xe8, +0x168) are read from the 15.7.8 binary; a family update shifts them loudly
  (same risk class as the reconstructed vtables).
- `RaphaeliVidMemory` geometry comes from family ivars at +0x40 (length) / +0xc8 (phys
  slot) — the reference-proven offsets, but the first real allocation on hardware must
  confirm them.
- Task pool is 32 allocators; the 33rd concurrent client task refuses (`createTask`
  logs FAILED, family sees a NULL task) — honest, and matches the reference's carrier
  math.
