# NullMoth 2.0.4 upstream sync survey

Date: 2026-10-16. Lane: research sync. No code changes in this report; verdicts and an absorb
plan only.

`research/nvidia-macos-driver` fast-forwarded cd8e2bb -> b737ded: 142 commits, driver 2.0.4.
Because cd8e2bb predates the 2.0.0 release, the range spans the whole 2.0.0 - 2.0.4 line, not just
the 2.0.4 delta. Zero commits touch `gpu-port/`; the kernel port is unchanged. 137 files changed,
11,535 insertions. File-tree breakdown: tools 63, translator 25, plugin 13, app 13, kexts 12,
docs 5, package 2, nvk 1.

Stack under consideration: Metal apps -> metal2vulkan/translator -> RADV -> amdgpu-port kext on
the 780M iGPU.

## 1. Categorized delta

### 1a. Translator (`translator/`, 7 commits, ~1,844 insertions)

All driver work for real games/apps on NVK. Behavioral changes to AIR -> SPIR-V output:

| Commit | Change | Behavioral effect |
|---|---|---|
| c19414b | Vector `fast_ldexp` in `passes/air_calls/rawbyte_unary.rs` | Accepts `ldexp(floatN, intN)` (scalar exponent splatted); previously refused, so WoW's texture-pool mask shader recreated pool pages every frame |
| 08d9f46 | `structured_emit/multi_exit.rs` funnels k loop exits; `reloop_nest/emit.rs` repairs dominance after nesting via function variables | Nested-CFG acceptance for >2-exit loops; WoW BVH kernel 100 ms -> 0.3 ms per dispatch. New `METAL2VULKAN_NEST` env knob for stage A/B |
| 0d0584d | Cube arrays (layer = slice*6+face), opaque image select rewrite (OpSelect on image loads -> index select + access chain, NonUniform carried), fcmp ord/uno via OpIsNan | WoW Classic: crash at launch and black screen fixed |
| 32afda2 | `structured_emit/plan_cache.rs` key hardened to a structural tuple; Scope made !Send/!Sync | Correctness guard: a hash/string collision can no longer serve a wrong cached plan |
| 10e9b51 | Loop/selection results reused across planner attempts (per-thread, Arc-identity keys) | Pure compile-time: Photos 232-block kernel 9.7 s -> 3.2 s; SPIR-V byte-identical |
| 39f543b | icmp on i1 and `<N x i1>` in `emitter/pointers/phi_compare.rs` (+ `tests/bool_vector_compare.rs`) | Apple GL lowering of bvec compares accepted; WebRender fragment pipelines no longer fail to software |
| 4ba580e | Nesting test follows the dominance repair | test only |

Plugin-side translation-path changes (same pipeline):

- c69856f: enable `robustBufferAccess` and `imageCubeArray` on the Vulkan device. NVIDIA-specific
  motive (unchecked OOB read = NVK MMU FAULT_PTE), but `robustBufferAccess` is a real behavioral
  difference for any driver: Metal apps read past buffer ends and Apple GPUs tolerate it. RADV
  accepts the feature; without it the same apps can read garbage past an allocation.
- 08ce634: AIR module hashed once per module instead of three times per dispatch, plus a 96 MB
  NSCache of recent translated cache files (VideoToolbox scaler re-creating its function per
  transfer). Same content-SHA cache-key idea our `NVMTLLibraryLoad.m` survey already noted.

**AMD-specific search**: `git log/diff cd8e2bb..HEAD` grepped for `AMD|APU|gfx1|RDNA|780M|radeon`.
Zero hits in `translator/` and zero in `plugin/`'s Vulkan-state code. Every translator change is
motivated by an NVIDIA/NVK failure. The only AMD content in the range is: the test-driver GPU
enumeration (setup scripts, section 3), NVRAM write guards for remapped AMD boards (2d97398,
app-level DisableVariableWrite), and package/changelog text.

Changelog commits read (457804b, db045a5, 2046e1e): 2.0.4 is entirely app/setup - "Prepare this
Mac for Tahoe" restore with cancel/rollback, switched-off Intel/AMD GPU recovery (-wegnoigpu,
disable-gpu, NPU-hidden GPU), a 1401-stick disk-list in the write log. No driver or translator
behavioral claims in the 2.0.4 changelog block itself.

### 1b. Kernel (`kexts/NVRM`, `nvk`, 12 files) - NVIDIA only

Sleep/wake rework (c0415f1, 5b65f51, eca4e53, 5583ee9: suspend RM+NVKMS, bounded sleep steps,
VRAM preserved across sleep), os_flush_work_queue implemented for the pre-sleep flush (13e4b01,
section 3), root-only GPU start, security series (map-owner key, cross-owner RAM map refusal,
user-client sentinel), BAR1 budgeting. All NVRM/NVKMS/NVRMFB-internal; no pattern our kext needs
today.

### 1c. Test driver / app / setup (AMD APU work)

- f3751e5: setup looks for the CPU's own GPU when its vendor is not on macOS's PCI list - Intel at
  `PciRoot(0x0)/Pci(0x2)` (`IGV=8086`), AMD APU behind `Pci(0x8,0x1)/Pci(0x0,0x0)` (`IGV=1002`,
  `-nmxamd`) - **even when an NPU is present** (Core Ultra 135U: an NPU used to make the app think
  no GPU existed). Vendor from CPU vendor id (AuthenticAMD -> AMD path).
- 7bd7bea: turn a GPU OpenCore switched off (disable-gpu / -wegnoigpu) back on for the test
  driver, and restore the exact previous OpenCore config when turned off ("switches it off again
  exactly as it was").
- 13e4b01: AMD/Intel-only Macs can install the NMXGPU/NMXAccel test driver from the package; plus
  the NVRM work-queue flush before sleep (1b).

This is all macOS app + `/bin/bash` setup-script logic (PCI-list sniffing, OpenCore config
read-modify-restore), not kext logic.

## 2. Lineage: NullMoth translator vs steelbrain metal2vulkan

- `docs/HOW-IT-WORKS.md:70` (NullMoth): shader translation "is based on metal2vulkan (LGPL-3.0)",
  and the vendored crate is literally named `metal2vulkan` (`translator/wrapper/Cargo.toml`
  depends on `metal2vulkan = { path = "../translator" }`).
- Same project lineage, **divergent forks**. steelbrain's repo is 0.2.0, "a full rewrite: nothing
  of 0.1.0's API or command line remains", restructured (`crates/metal2vulkan/src/{lower,
  structurize,pipeline,...}`); NullMoth's vendored copy keeps the older layout (`src/{native,
  passes,emitter,...}` with `reloop_nest`, `structured_emit`). The 7 NullMoth translator commits
  are in-tree fixes to their fork, by NullMoth Systems / modest-tao / razvanccr - steelbrain
  (Anees Iqbal) has **zero** commits in the NullMoth tree, and none of the seven features
  (`fast_ldexp`, k-exit funnel, bool-vector icmp, plan-cache hardening) appears in the 0.2.0 tree
  under the same names. Neither side is taking the other's commits 1:1.
- Who supports AMD: upstream metal2vulkan has explicit, measured AMD/RADV lanes - the +31 FF we
  absorbed includes 61a2efc ("Fix the GPU test failures seen on the 3090, 5080, XTX, 780M and
  M3": RADV <26.2 implicit-preprocess-after-execution-set GPU fault, worked around as
  `RuntimeDriverDefect::ImplicitPreprocessAfterExecutionSet`), 81c82b1 ("Fix the RX 7900 XTX and
  780M lanes' findings": amdgpu 2 s `lockup_timeout` ring-reset workaround in the validation
  lanes), 4079f17, 30c8b4b/dd5a19a (padded-texture shadow), 48db6e7, and FAST-PATHS.md measurements
  on a 780M (Mesa 26.0.8 / 26.2.4). NullMoth's fork has no AMD lanes at all (it targets NVK).

**Right userspace layer for an AMD iGPU: upstream metal2vulkan (steelbrain), which we already
chose** (`docs/reports/metal-plugin.md`: build on metal2vulkan-runtime, RADV underneath). NullMoth's
translator is only useful as a source of battle-tested translation cases, not as the runtime.

## 3. Test-driver patterns vs our `nmx_kext.cpp` attach guard

Our guard (`Raphaeli/Kernel/nmx_kext.cpp:150-216`): NVRAM marker `raphaeli-gpu-attaching` set
before attach/cleared after; a boot that finds it set parks the GPU permanently until the user
toggles the test driver. Their work solves a different problem but two patterns are worth noting:

1. **Device enumeration guard** (f3751e5): the CPU's own GPU at fixed PCI paths (Intel 00:02.0,
   AMD APU behind 00:08.1) is looked up *whenever its vendor is missing from the visible list, and
   even when an NPU is present*. Our kext matches whatever IOPCIMatch hands it; the 780M
   (`1002:15bf` class) is not NPU-shadowable, but if we ever enumerate by expected-path rather
   than match, the "NPU does not hide the GPU" ordering is the pattern: match by vendor+expected
   bridge slot, never by absence of other compute accelerators. **No change needed today.**
2. **Restore-exactly-as-was** (7bd7bea): before mutating any boot state, capture the prior value
   and restore it verbatim on off. Our attach guard's recovery currently requires a manual
   off/on toggle; a cheap mirror would be clearing `raphaeli-gpu-attaching` automatically after one
   clean attach cycle (marker set -> clean `attach_ = 1` -> marker already cleared) so a single
   panic does not need manual recovery. That is a behavior change to the guard, **absorb-lane,
   not now** - current semantics are safe-by-default.
3. **Flush work before sleep** (13e4b01): NVRM counts in-flight work items and implements
   `os_flush_work_queue` (30 s deadline, refuses from interrupt context) so RM's power path drains
   queued work before the GPU suspends. Our `setPowerState` (`nmx_kext.cpp:269-277`) calls
   `nmx_port_power` with no in-flight work accounting - but we also have **no work queue** in the
   kext yet (grep: only the attach thread). Pattern to remember the day a workqueue appears;
   nothing to absorb now.

## 4. Verdicts

| Area | Verdict | Why |
|---|---|---|
| gpu-port/ kext | ignore | zero commits touch it |
| NullMoth translator (7 commits) | absorb-lane | NVIDIA-motivated, but each is a Metal-app compatibility class (bool-vector icmp = WebRender, ldexp/image-select = WoW) that will hit our RADV path too. Port as upstream metal2vulkan work items, not as a fork of NullMoth's code |
| Plugin robustBufferAccess (c69856f) | absorb-now (flag only) | when our Metal-on-Vulkan layer lands, default `robustBufferAccess = VK_TRUE` on the device; RADV is fine with it and Metal apps rely on the tolerance |
| Translation cache design (08ce634: hash-once + bounded memory cache) | absorb-lane | good perf pattern for our `libnvmtl_translate` replacement; adopt when the plugin layer is written |
| Test driver / app / setup AMD APU work | ignore | app+OpenCore scripting; our kext matches by PCI id, no NPU-shadowing path |
| NVRM sleep/wake + flush | ignore (note 3 above) | NVRM-internal; pattern only |
| Security series (map-owner key, cross-owner map) | absorb-lane | NVRM API-specific, but the threat (a process mapping another's RAM through the driver) maps to our `nmx_vm.cpp`; audit our map paths against it when accel user clients land |
| Upstream metal2vulkan 780M/RADV fixes (61a2efc, 81c82b1, ...) | already absorbed | included in the +31 FF to 720ef1c in `research/metal2vulkan` |

## 5. Absorb plan (translator work, if taken)

Do not fork NullMoth's translator. Route through upstream metal2vulkan, where our stack lives:

1. **File a checklist against `crates/metal2vulkan/src` at 720ef1c** (one task each, test-first):
   - icmp on i1 / `<N x i1>` (bvec compares) - if the 0.2.0 structurizer already lowers it, close
     with NullMoth's `tests/bool_vector_compare.rs` ported as the regression case.
   - `ldexp(floatN, scalar-int)` acceptance (`lower/arith`), with rawbyte_unary's splat semantics.
   - Multi-exit loop funneling + post-nest dominance repair (`structurize/`), with
     `METAL2VULKAN_NEST`-style stage knob only if a real module needs it.
   - Cube-array coordinate fold and opaque image-select rewrite (`NonUniform` preservation) -
     the image-select form matters on RADV too (selecting on image values is fragile across
     drivers, which is why NullMoth rewrote it after an NVK trap).
2. Order: bool-vector icmp first (WebRender-class failure, smallest), then ldexp, then
   image-select/cube-array, then multi-exit dominance. Each lands with a fixture from the
   offending Metal app class plus a spirv-val round-trip.
3. Nothing here blocks the kext or RADV bring-up; it is userspace translation hardening for the
   app-compatibility phase.

## 6. Bottom line

2.0.4's AMD story is install/recovery tooling, not translation: the NullMoth translator gained
real AIR->SPIR-V quality fixes with zero AMD specificity, and everything AMD-relevant to our stack
(780M/RADV device profiles, defect workarounds) already arrived via the metal2vulkan FF to
720ef1c. The only adopt-now item is the `robustBufferAccess` device flag decision for our future
Metal-on-Vulkan layer; everything else is a lane.
