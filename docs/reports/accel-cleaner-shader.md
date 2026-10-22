# Accel cleaner shader: research findings

Status: **research only. No Raphaeli code uses the cleaner shader. No source edits.**

Scope: bounded static read of the pinned amdgpu tree. Hardware behavior is unverified (no Phoenix target here).

## Sources

- `kpi/drm-kmod/drivers/gpu/drm/amd/amdgpu/` (pinned kpi HEAD `c16de0f9fa`)
- `research/drm-kmod/drivers/gpu/drm/amd/amdgpu/` (HEAD `c16de0f`)
- `amdgpu_gfx.c`, `amdgpu_vm.c`, `amdgpu_ib.c`, `amdgpu_mes.c`, `gfx_v11_0.c` are byte-identical in both trees (`cmp`).
- Line refs below are against the pinned kpi tree.

## Finding 1: sysfs-only, non-VM cleaner job

`amdgpu_gfx.c`:

- `:1409` `amdgpu_gfx_run_cleaner_shader_job(ring)` (`static`):
  - `drm_sched_entity_init(&entity, NORMAL, &ring->sched, 1, NULL)`.
  - `amdgpu_job_alloc_with_ib(adev, &entity, NULL, 64, 0, &job)`. VM argument is `NULL`.
  - `job->enforce_isolation = true`.
  - Fills `ib->ptr` with `ring->funcs->nop` over `align_mask + 1` dwords.
  - `amdgpu_job_submit(job)`, `dma_fence_wait(f, false)`, then `drm_sched_entity_destroy`.
- `:1456` `amdgpu_gfx_run_cleaner_shader(adev, xcp_id)`: picks the first ready compute ring per XCC with matching `xcp_id`. Returns `-ENOENT` if an XCC has no ready ring.
- `:1505` `amdgpu_gfx_set_run_cleaner_shader`: write-only sysfs attr `run_cleaner_shader`, mode `0200` (`:1683-1684`).
  - `:1514-1515` rejects `-EPERM` if `amdgpu_in_reset` or `in_suspend && !in_runpm`.
  - `:1526-1533` range check: `< xcp_mgr->num_xcps`, or `<= 1` without xcp_mgr.
  - `:1537` `pm_runtime_get_sync` around the run (`:1542` runs the cleaner).
- `:1753-1754` attr is created only when `adev->gfx.enable_cleaner_shader` is set (removed under the same guard at `:1762-1763`).

The only trigger for the job is that sysfs write. It is not reachable from the IB/submit path.

## Finding 2: VM flush inline path

`amdgpu_ib.c`:

- `:166` `if (!ring->sched.ready && !ring->is_mes_queue)` → `-EINVAL`. Ring not scheduler-ready is refused here.
- `:171` `if (vm && !job->vmid && !ring->is_mes_queue)` → `-EINVAL`. Job with a VM and vmid 0 is refused here.
- `:214` `if (job) { ... amdgpu_vm_flush(ring, job, need_pipe_sync) }` (`:215` call). Skipped entirely when `job == NULL`.

`amdgpu_vm.c` `amdgpu_vm_flush` (`:753`):

- `:788-789` early return (`return 0`): skipped only if no VM flush, no GDS switch, no pipe sync, and not `(enforce_isolation && !vmid)`. The sysfs job (vmid 0, enforce_isolation) still reaches the emit.
- `:800-803` emits the cleaner inline, before the VM flush, when all hold:
  `adev->gfx.enable_cleaner_shader && ring->funcs->emit_cleaner_shader && job->enforce_isolation`.
- `:805-806` VM flush itself runs only if `vm_flush_needed` (`job->vm_needs_flush`, gated on `emit_vm_flush` and a valid `vm_pd_addr`).

Ring emit:

- `gfx_v11_0.c:6822` `gfx_v11_0_ring_emit_cleaner_shader` writes `PACKET3(PACKET3_RUN_CLEANER_SHADER, 0)` (`:6825`, `0xD2` at `soc15d.h:416`) plus one zero dword.
- `gfx_v12_0.c:5067` same shape (packet at `:5070`).

Note: `vm_needs_flush` for the VM-less sysfs job was not traced further. Treat "no VM flush for the sysfs job" as unverified.

## Finding 3: enable gating (per IP)

`enable_cleaner_shader` is set in each `gfx_v*_0.c` `sw_init`-time switch, with firmware/MES version floors:

- `gfx_v11_0.c:1589-1607`: `case IP_VERSION(11, 0, 0)` (`:1589`), `(11, 0, 2)` (`:1590`), `(11, 0, 3)` (`:1591`) only. Enable at `:1598` requires `me_fw >= 2280`, `pfp_fw >= 2370`, `mec_fw >= 2450`, `mes fw_version[0] >= 99`. `default:` at `:1606-1607` disables.
- `gfx_v12_0.c:1335-1363`: IP 12.0.0 / 12.0.1 (`:1335-1336`). Enable at `:1361`. `default:` at `:1363`. Floors `me 2480`, `pfp 2530`, `mec 2680`, `mes 100` (floors in the same switch, not re-read in this pass).
- `gfx_v10_0.c:4751`: IP 10.3.x switch (`:3864-3882` region). Floors `me 64`, `pfp 100`, `mec 122`.
- `gfx_v9_0.c:2240`, `gfx_v9_4_3.c:1080`: same pattern.

### Phoenix GC IP: not verified

- `gfx_v11_0.c` **does** list `IP_VERSION(11, 0, 3)` (`:1591`). An earlier version of this note said Phoenix was absent from the GFX11 list. That was wrong.
- `amdgpu_discovery.c:2706-2711` maps GC `11.0.0`, `11.0.2`, `11.0.3` to family `AMDGPU_FAMILY_GC_11_0_0`. `11.0.1` and `11.0.4` map to `AMDGPU_FAMILY_GC_11_0_1`.
- The actual Phoenix GC version comes from the discovery table at runtime. This pinned tree contains no static Phoenix (`0x15bf`) to GC mapping that was found in this pass. The scout claim "discovery GC `IP_VERSION(11,0,3)`" was **not reproduced** from the pinned source or from Raphaeli files.
- **Conflict:** Raphaeli stages `gc_11_0_1_*` firmware for Phoenix (`Raphaeli/Firmware/stage.sh:21-37`; `Raphaeli/Firmware/README.md:17` names "GC IP 11.0.1"). GC 11.0.1 is **not** a cleaner-enabled case in `gfx_v11_0.c`, so cleaner stays disabled on that path. If the runtime GC is 11.0.3, the firmware set and the cleaner floors would need checking against each other.
- Treat cleaner as disabled on Phoenix until the runtime GC IP and firmware versions are read on target hardware.

MES: `amdgpu_mes.c:1711` pushes enforce-isolation updates only when `enable_mes && enable_cleaner_shader`. `MESAPI_MISC__LAUNCH_CLEANER_SHADER` exists in `kpi/drm-kmod/drivers/gpu/drm/amd/include/mes_v11_api_def.h:579` and `mes_v12_api_def.h:648`. Not traced further.

## Finding 4: Raphaeli matches

Searched `Raphaeli/`, `scripts/`, `docs/` (case-insensitive) for: `cleaner`, `enforce_isolation`, `run_cleaner`, `enable_cleaner`, `emit_vm_flush`, `amdgpu_vm_flush`, `amdgpu_gfx_sysfs`, `device_create_file`.

- **No matches** for cleaner, enforce_isolation, run_cleaner, emit_vm_flush, amdgpu_vm_flush, sysfs attr creation.
- Only unrelated hits: `Raphaeli/Firmware/README.md:17` and `stage.sh:11` name `gfx_v11_0.c` as the firmware consumer. No cleaner logic.

Closest Raphaeli code: `Raphaeli/Override/src/nmx_accel_bridge.c:98` `nmx_accel_bridge_submit` calls `amdgpu_ib_schedule(gring, 1, &ib, NULL, &f)`. Job is `NULL`, so `amdgpu_ib.c:214-215` is skipped and no cleaner is emitted. The file header (`:7`) states this design explicitly ("no job and no VM").

### Runtime guards on the bridge submit path (`nmx_accel_bridge.c:78-106`)

- `:81-82` `ib_addr == 0 || ib_dw == 0` → `-EINVAL`.
- `:84-85` no device, or `!adev->accel_working` → `-ENODEV`.
- `:87-88` `in_suspend || shutdown` → `-EBUSY`.
- `:89-90` `ring >= adev->gfx.num_gfx_rings` → `-EINVAL`.
- Scheduler-ready is not checked here. The `sched.ready` check is in `amdgpu_ib.c:166` and returns `-EINVAL` from inside `amdgpu_ib_schedule`.

## Why no safe reuse

1. `amdgpu_gfx_run_cleaner_shader_job` is `static`. Override cannot call it. Copying it means re-implementing a scheduler job path inside the bridge.
2. That job path needs an `amdgpu_job` with `enforce_isolation` and a `drm_sched_entity`. The bridge uses `job == NULL` on purpose. Passing a job changes `amdgpu_ib_schedule` behavior (`amdgpu_vm_flush` at `amdgpu_ib.c:215`, `vmid` check at `:171`).
3. Using a real job with a VM would need the per-task VM bridge that `docs/reports/accel-vm-gate.md` marks as **blocked**. A global or NULL VM for a client job is what that gate forbids.
4. Enable gating depends on exact GC IP and MES/PFP/ME/MEC firmware versions. Raphaeli does not check these for Phoenix, and staged firmware (`gc_11_0_1`) does not match an enabled case. Calling the sysfs path blindly on a disabled ring would fail or no-op.
5. Constraint 3 (`AGENTS.md`: failure paths non-panicking, no unvalidated amdgpu internals) plus constraint 2 (unknown selectors → `kIOReturnUnsupported`) argue against adding a cleaner path without a validated contract.

Net: reuse is unsafe today. The cleaner is a sysfs-triggered, job-based, enable-gated feature. Its only inline emit is in the VM flush path under `enforce_isolation`, and Raphaeli's submit path avoids that path on purpose.

## Options

- **A. Keep as-is (recommended now).** Document only. No cleaner in bridge or kext. Matches the blocked VM gate.
- **B. Bridge-owned cleaner job.** Re-implement the job path in `Override/src/` with a task VM. Blocked on `accel-vm-gate.md` contract and on Phoenix enable verification (runtime GC IP plus firmware floors). Larger change, new security surface.
- **C. Expose `run_cleaner_shader` via kext/sysfs.** Out of scope for Raphaeli. Would also require the device sysfs attr, which is created only when enabled.

## Acceptance criteria (for any follow-up)

- Option A: this report stays accurate against pinned `kpi/` HEAD. No kext or bridge behavior change. `git diff --check` clean.
- Option B (not approved): verify runtime Phoenix GC IP maps to a cleaner-enabled case and firmware floors are met on target; task VM contract from `accel-vm-gate.md` implemented; bridge never passes a NULL-VM job with `enforce_isolation`; host/kernel build stays 900/900 and 81/81; no panics on disabled ring (`sched.ready` false) or in-reset.
- Any option: no edits under `kpi/` or `deps/`.

## Open risks / unverified

- Phoenix runtime GC IP: scout's `IP_VERSION(11,0,3)` claim not reproduced. Staged firmware is `gc_11_0_1_*` (Finding 3). Cleaner enablement on Phoenix is unknown.
- `vm_needs_flush` value for the sysfs job not traced.
- MES `LAUNCH_CLEANER_SHADER` path not traced.
- `gfx_v12_0.c` and `gfx_v10_0.c` floor values not re-read in this pass.
- Hardware behavior unverified (no target Phoenix here).
