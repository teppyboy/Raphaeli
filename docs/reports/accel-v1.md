# IOAccelerator lane — real ring/fence bridge (v1)

Task: wire `nmx_xnu_accel_ring_submit` / `nmx_xnu_accel_fence_wait` (previously v0
log-and-refuse, see accel-family.md) to the port's real submission path. The accel UC
objects stay log-only until their protocol mapping is proven; the hooks are the reusable
core. Untouched: `nmx_fb*`, `bsdcompat/src/nmx_scanout*`, `Info.plist`; the
unknown-selector `kIOReturnUnsupported` invariant is unchanged (`newUserClient` still
delegates to the family).

## 1. How a RADV submit flows today (study result)

libdrm/RADV issue `DRM_IOCTL_AMDGPU_CS` on the port's DRM device node; the kernel side
is `amdgpu_cs_ioctl` (`kpi/drm-kmod/drivers/gpu/drm/amd/amdgpu/amdgpu_cs.c`) → parser →
`amdgpu_cs_submit` → `amdgpu_ib_schedule` on the selected `amdgpu_ring`, which emits the
IB packets and `amdgpu_fence_emit` and returns a `dma_fence`. The port runs that path
inside Raphaeli.kext: `nmx_port_attach` (Compat/src/nmx_port.c) adds the claimed
IOPCIDevice to the FreeBSD-on-xnu bus (nmx_bus.c), amdgpu probes (`amdgpu_pci_probe`),
and keeps its `drm_device` as the PCI driver data (`pci_set_drvdata`) — the same handle
the display bridge resolves (`drm_of`, Override/src/nmx_fb_bridge.c). User clients drive
this through the DRM device nodes; a kernel-internal submit does not need a drm_file:
amdgpu's own ring tests (`gfx*_ring_test_ib`) call `amdgpu_ib_schedule(ring, 1, &ib,
NULL, &fence)` with no job and no VM — that is the minimal in-kernel submit, and the
shape v1 uses.

## 2. Implementation

**Override/src/nmx_accel_bridge.c (new; the whole real path).** The IOKit side compiles
against Apple's headers only, so the hooks delegate over the `nmx_port.h` boundary to
this TU, which sees amdgpu:

- `nmx_accel_bridge_device(iopci)` — registers the GPU whose driver attached; resolves
  the amdgpu child like `drm_of` (`nmx_device_for_pci` → attached child →
  `pci_get_drvdata` → `drm_to_adev`, verified by `drm->driver->name == "amdgpu"`).
  v1 serves one device (the last registered; a second registration logs a note).
- `nmx_accel_bridge_submit(ring, ib_addr, ib_dw, fence_out)` — refuses on no device /
  `!accel_working` (`-ENODEV`), suspend/shutdown (`-EBUSY`), unknown ring (`-EINVAL`);
  otherwise zeroes an `amdgpu_ib`, points it at the caller's IB (`ib.gpu_addr =
  ib_addr`, `length_dw = ib_dw`; the contents are the caller's, as in every real
  submit), and runs `amdgpu_ib_schedule(&adev->gfx.gfx_ring[ring], 1, &ib, NULL, &f)`.
  The schedule's dma_fence is returned as an opaque handle (one reference owned by the
  caller of the hook); if the caller passes `fence_out == NULL` the fence is dropped.
  `amdgpu_ib_schedule` itself refuses on `!ring->sched.ready` — no panics, all errors
  return.
- `nmx_accel_bridge_fence_wait(fence, timeout_ms)` — `dma_fence_wait_timeout(f, false,
  msecs_to_jiffies(timeout_ms))`, then `dma_fence_put`. `fence == 0` → `-EINVAL`;
  timeout → `-ETIME`. The handle is consumed: one wait per fence (kernel-internal v1
  contract, documented in the file header).

**Kernel/nmx_accel.cpp** — the hooks map bridge results: 0 → `KERN_SUCCESS`,
`-ETIME` → `KERN_OPERATION_TIMED_OUT`, everything else → `KERN_NOT_SUPPORTED` (so the
gate holds: before the driver attaches, suspended, detached — the hooks are no-op-safe
and refuse). First 8 calls of each op still sample-log the contract surface.

**Kernel/nmx_kext.cpp (the one call site)** — `Raphaeli::attachNow`, right before
`attach_ = 1`: `nmx_accel_bridge_device(pci_); nmx_accel_selftest();`. Registration
lives at attach time so the bridge always points at a fully attached driver (the accel
nub matches later and asynchronously).

**Selftest** (`nmx_accel_selftest` in the same bridge file; inert without boot arg
`raphaeli-accel-test=1`, mirrors the scanout selftest pattern): allocates one 4 KiB GTT
buffer (`amdgpu_bo_create_kernel`), writes two `PACKET3(NOP, 0)` dwords (soc15d.h, same
opcode across gfx9–gfx12), pushes it through the *hooks* (`nmx_xnu_accel_ring_submit(0,
gpu_addr, 2, &fence)` → `nmx_xnu_accel_fence_wait(fence, 5000)`), logs
PASS/FAIL, frees the buffer. A failure leaves nothing behind and cannot affect the
driver.

**Compat/include/nmx_port.h** — the four bridge declarations (plain types only, copied
to `nmxxnu/` for the C++ side by ccxx.sh as before). **scripts/gen_ccdb.sh** — ccdb
entries now also cover `Override/src/*.c` with the real cclk.sh flags (clangd was
parsing those header-less; compile_commands.json is a generated artifact).

## 3. What this buys / what it is not

- A kernel-internal caller (the accel lane, the future UC bridge, tests) can execute a
  real IB on the gfx ring and wait on the real dma_fence — the exact primitives
  `amdgpu_cs_ioctl` builds on, minus the user-client machinery.
- It is not yet the RADV path: no VM/GTT mapping from accel-side objects, no job/sched
  entity (direct schedule instead of the scheduler queue), no syncobj. Those are the
  protocol-mapping work of the next lane.

## 4. Validation

- `scripts/build.sh`: 900/900 port sources compiled, 0 failed.
- `scripts/rt.sh`: 78 runtime sources, 0 failed (`lkobj/nmx_accel_bridge.o`).
- `scripts/link.sh out-disp`: links clean (`Raphaeli b4d26158, 10981960 B`); the four
  bridge symbols and the two hooks resolve internally (no undefined accel symbols).
- `kmutil inspect -V tb -p $PWD/out-disp/Raphaeli.kext` → exit 0.
- Selftest is hardware-gated (`raphaeli-accel-test=1` on the target Mac); the log line
  to look for: `Raphaeli accel selftest: gfx ring 0 NOP IB submitted, fence signaled:
  PASS (0x0)`.

## 5. Residual risks

- The fence handle is a raw dma_fence pointer; only kernel-internal callers hold it and
  each handle must be waited (or leaked). Userland never sees it.
- Ring index 0 = `gfx_ring[0]`; a real queue mapping (compute/sdma rings, MES) is later
  work — unknown ring refuses with `KERN_NOT_SUPPORTED`.
- Multi-GPU: hooks serve the last-registered device; a second GPU gets honest refusals.
- The selftest's NOP IB relies on `PACKET3_NOP` staying 0x10 across gfx generations the
  kext supports (true for gfx9–gfx12 today).
