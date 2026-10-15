# NMXGPU kext — static runtime-hazard audit (pre-first-load)

Scope: static audit only, no files modified. Repo: `Raphaeli/xkpi` (bsdcompat/ = BSD compat layer, xnu/ = IOKit glue, override/ = source forks, obj/ = 902 amdgpu/drm/ttm objects, kext/Info.plist = bundle). Linked binary audited: `out/NMXGPU.kext/Contents/MacOS/NMXGPU` (x86_64 Mach-O). drm-kmod sources referenced from `Raphaeli/kpi/drm-kmod` (FreeBSD 6.14-track, commit c16de0f). Ranked P0 (blocks load), P1 (crash on attach), P2 (latent).

---

## 1. IOKit glue (xnu/nmx_kext.cpp)

**[P0-1] kmod name and executable layout do not match the bundle — load will be refused or the binary never found.**
- `xnu/nmx_kext.cpp:294-300`: `KMOD_EXPLICIT_DECL(com.nullmoth.NMXGPU, "1.0.0", _start, _stop)`. Binary strings confirm `com.nullmoth.NMXGPU`.
- `kext/Info.plist:5`: `CFBundleIdentifier = com.raphaeli.Raphaeli`; `Info.plist:7`: `CFBundleExecutable = Raphaeli`; binary is linked to `NMXGPU.kext/Contents/MacOS/NMXGPU` (`link.sh:16-18`).
- kxld requires the kmod_info name to equal the CFBundleIdentifier and the executable name to match CFBundleExecutable. All three disagree → `kextutil`/kextd refuses the kext (or the AppleSDK load path fails on the missing `Contents/MacOS/Raphaeli`).

**[P0-2] IOClass mismatch: IOKit can never instantiate the service.**
- `kext/Info.plist:13,25`: `IOClass = Raphaeli`. The binary registers the C++ class `NMXGPU` (`xnu/nmx_kext.cpp:25` `OSDefineMetaClassAndStructors(NMXGPU, IOService)`; metaClass symbol `NMXGPU` in the binary; also `NMXGPUFB` for the bridge).
- No class named `Raphaeli` exists in the kext → both personalities die at matching ("can't instantiate IOClass"), `probe()`/`start()` never run. The kext would load and match nothing. (Also: no `IOClass` named in the binary is referenced by the plist at all.)

**[P0-3] Opt-in contract mismatch: even a successful match would always decline.**
- Code: `opted_in()` (`xnu/nmx_kext.cpp:37-48`) reads boot args `nmxamd` / `nmxintel` and the device property `nullmoth-gpu`.
- `kext/Info.plist:16-18, 26-27` (comments): promises `raphaeli-amd=1` / `raphaeli-intel=1` and property `raphaeli-gpu`. None of those is read by the binary. Following the plist's documented knobs, `probe()` returns nullptr for every device.

**probe() decline for the Reims vGPU — safe.**
- `xnu/nmx_kext.cpp:51-58`: `probe()` casts the provider to IOPCIDevice, reads vendor via config space; vendor `0x106b` (Apple/Reims vGPU `106b:eeee`) is neither `0x1002` nor `0x8086` → `return nullptr` before any port state is touched. `opted_in()` would also decline absent boot args/property. A non-PCI provider (`pci == nullptr`) yields vendor 0 → declined.
- Belt and braces: the personalities' `IOPCIPrimaryMatch` (`Info.plist:15,24`) only matches vendors `0x1002`/`0x8086`, so the vGPU never even reaches `probe()`.

**[P1-1] start() is not gated on real BARs/MSI.**
- `xnu/nmx_kext.cpp:65-97`: `start()` checks only `pci != nullptr`, `g_lock != nullptr`, and `IOService::start`. It then runs the entire port bring-up (`nmx_port_start()`, `bsdcompat/src/nmx_port.c:29-45`: kernel/malloc/page/sleepq/callout/taskqueue/devfs + all SYSINITs, including `amdgpu_init`'s `pci_register_driver`, `amdgpu_drv.c:3032-3033`) and spawns the attach thread *before* any evidence that the device has addressable BARs or any interrupt source.
- First BAR touch is inside amdgpu's probe/attach: `bus_alloc_resource_any` → `nmx_xnu_pci_map_bar` (`bsdcompat/src/nmx_bus.c:775-820`, `xnu/nmx_pci.cpp:63-78`). Mapping failure is handled there (NULL resource), but every driver path that assumes a successfully mapped MMIO window then reads through `rman_get_virtual`. On a vGPU with truncated/absent BARs the first such read is a NULL-page deref, not a clean decline. A cheap gate (probe reads BAR0 size, requires ≥1 MMIO BAR and ≥1 interrupt source) is missing.
- MSI is likewise unverified at start: `nmx_xnu_pci_msi_count` (`xnu/nmx_pci.cpp:135-149`) can legitimately return 0 in a VM.

**Other glue observations (P2).**
- `NMXGPU::stop` (`xnu/nmx_kext.cpp:249-266`) busy-waits up to 6000×100 ms (10 min) for a running attach while blocking the provider workloop — a hung attach wedges termination.
- `nmx_kmod_stop` (`xnu/nmx_kext.cpp:279-296`) frees `g_lock` while a concurrent `NMXGPU::start` may still hold it; IOKit matching serialization makes this unlikely but it is unguarded.
- Attach-failure degrade path (`kernel_thread_start` failure, `nmx_kext.cpp:86-93`) returns `true` from `start()` with `attach_ = -1`: the device is left claimed-but-dead; stop() still tears down cleanly.
- NVRAM boot guard (`nmx_kext.cpp:126-176`): marker never cleared on a hang parks the GPU on every subsequent boot until manually reset — deliberate, but a real availability hazard on first bring-up.

---

## 2. LinuxKPI/bsdcompat init order (SYSINIT vs IOKit start)

Ordering machinery is sound:
- All SYSINITs live in section `__DATA,nmx_sysinit` (`bsdcompat/include/sys/kernel.h:54-76`); `nmx_sysinit_run` sorts by (subsystem, order) and *refuses to start if the set is empty* (`bsdcompat/src/nmx_kernel.c:405-411`) — good defense against a linker section silently dropped.
- Statically declared mutexes (`MTX_SYSINIT`, `sys/mutex.h:69-73`) run at `SI_SUB_LOCK`, before `SI_SUB_DRIVERS`; `nmx_port_start` (`nmx_port.c:29-45`) brings up lock group → malloc → page → sleepq → callout → taskqueue → devfs, and only then runs the SYSINIT set, so every consumer of those mutexes/zones/timers is initialized first. `nmx_sysinit_run` itself runs after the allocators it needs.
- `module_init(amdgpu_init)` (`amdgpu_drv.c:3073` via `linux/module.h`) lands at `SI_SUB_OFED_MODINIT` (`SI_SUB_ROOT_CONF - 1`), i.e. after all `SI_SUB_DRIVERS` inits — driver registration (`linux_pci_register_driver` → `devclass_add_driver`, `override/src/linux_pci.c:1244-1262`) happens after `devclass_create("vgapci")` infrastructure exists.
- Taskqueues/callouts: `nmx_taskqueue_init`/`nmx_callout_init` are explicit STEP 5/6 of `nmx_port_start` (`nmx_port.c:33-34`); the softclock thread (`nmx_task.c:81-127`) and taskqueue threads are running before any driver code can enqueue. No uninitialized taskqueue/timer window found on load.
- UMA zones used by the DMA path (`linux_dma_obj_zone`, `override/src/linux_pci.c:1712-1730`) are SYSINIT-created (`SI_SUB_DRIVERS, SI_ORDER_THIRD`) — again before any device attaches (devices only appear in `nmx_port_attach`, after `nmx_sysinit_run`).

**[P2-1] NULL function-table guards.** `nmx_device_method` (`nmx_bus.c:461-470`) returns NULL for missing methods and every call site (`probe_with`, `device_attach`, `device_detach`) null-checks. One latent hole: `device_probe_and_attach` (`nmx_bus.c:528-545`) dereferences `dev->driver->name` at `nmx_bus.c:544` after `probe_with` success — driver is non-NULL by construction there, OK — but `probe_with` (`nmx_bus.c:492-506`) treats a *negative* probe return as success without checking `dev->driver` was set by `set_driver`; if a driver's softc allocation failed (`set_driver` returns ENOMEM) the child is deleted cleanly. No NULL-call found.

**[P2-2] Legacy-line fallback in a VM.** `pci_alloc_msix` is unconditionally `ENXIO` (`nmx_bus.c:999`); `pci_alloc_irq_vectors` (`override/src/linux_pci.c:1584-1620`) falls back MSI → legacy. If a VM exposes neither MSI messages nor a legacy index, `nmx_xnu_pci_irq_setup` returns `kIOReturnNotFound` (`xnu/nmx_pci.cpp:151-162`) and amdgpu's irq init fails → attach error (clean, not a crash). Reims vGPU MSI topology is the unknown; verify before first load on metal.

---

## 3. amdgpu probe path

**No AMD device present — clean decline confirmed.**
- `nmx_port_attach` → `attach_on` (`nmx_port.c:75-99`): creates the device record, `nmx_bus_add_device(dev, "vgapci")`, then `device_get_children`/`device_is_attached`; if no driver attached → `nmx_bus_remove_device` + `nmx_device_forget` and returns NULL. The kext logs "no driver took …" and the GPU stays with macOS. No leaked records: `free_record` removes resources/dmat.
- Inside the bus, `offer()` (`nmx_bus.c:590-608`) creates a child, `probe_with` → `linux_pci_probe` (`override/src/linux_pci.c:596-612`): `linux_pci_find` fails to match the pciidlist → `ENXIO` → child deleted. On the VM there is no `0x1002` function at all, so this path is not even reached.
- Note: `amdgpu_init`'s `amdgpu_acpi_detect()` (`amdgpu_drv.c:3033`, `amdgpu_acpi.c:1413-1427`) iterates `pci_get_base_class(PCI_BASE_CLASS_DISPLAY, …)` — the port's `pci_find_base_class_from` walks only port-registered devices, none of which exist at SYSINIT time, so it is a no-op on load (functional gap for hybrid-graphics ATPX, not a crash).

**With the 780M present (0x15bf matches the `CHIP_IP_DISCOVERY` display-class wildcards, `amdgpu_drv.c:2163-2176`): concurrent paths at attach and the top 10 likely-first-crash sites**, in execution order:

1. **Bundle/kmod/class-name mismatch (P0-1/2/3)** — happens before `probe()`; the attach never starts. Fix first.
2. **BAR0 MMIO map + first RREG32.** `amdgpu_device_init` ioremaps the MMIO window via `_ioremap_attr` → `pmap_mapdev_attr` (`override/src/linux_page.c:302-313`, implemented). On a vGPU, a trapped or zero-length BAR0 makes discovery reads return 0xffffffff/garbage. Site: `obj/amdgpu_discovery.o` / `amdgpu_device.c` early_init — first MMIO touch is the first hardware access of the whole attach.
3. **IP-discovery table parse → NULL hw-block function tables.** `amdgpu_discovery_init` (obj/amdgpu_discovery.o) builds IP block lists from the table read over MMIO; on Phoenix (DCN 3.1.x) a bad/truncated table yields blocks whose `hwseq`/`funcs` pointers stay NULL — the first call through one (typically during DC resource construction) is a classic drm-kmod crash.
4. **ATOM BIOS fetch/parse.** `amdgpu_bios.o`/`amdgpu_atombios.o`: APU BIOS is located via the MMIO VRAM window/ACPI; a partial BIOS image reaching `amdgpu_atom_parse` gives NULL table pointers inside `amdgpu_atombios.c` lookups (powerplay, connector tables) — guarded inconsistently upstream.
5. **Firmware load.** `linuxkpi_request_firmware` → `firmware_get_flags` → `nmx_xnu_firmware_load` (`bsdcompat/src/nmx_firmware.c:31-63`, `xnu/nmx_platform.cpp:59`, root `/Library/NullMoth/firmware/`, `nmx_platform.cpp:33`). Missing files are clean failures, but partial installs (some ucode present, e.g. SMU without DMUB) can pass a zero-sized image into `amdgpu_ucode.o` parsing — check `fw->datasize` guards before first load.
6. **ACPI evaluation (`_DSM`/ATIF/ATCS).** `AcpiEvaluateObject` → `nmx_xnu_acpi_evaluate` (`bsdcompat/src/nmx_acpica.c:309-377`, `xnu/nmx_platform.cpp:387`). The reply-buffer conversion (`buffer_reserve`/`result_fill`, `nmx_acpica.c:368-377`) is hand-rolled for each ACPI object type; a VM's nonstandard DSDT package shape is a plausible memory-stomp site.
7. **DC/DM bring-up (436 display objects built, `srcs.txt`).** `dc_create` → DCN31 resource/clk_mgr construction, `dmub` hw init (needs `dmub` firmware from site 5), HPD/backlight registration through `nmx_backlight.c`. Largest untested code mass; historically the #1 crash area of drm-kmod-on-other-OS ports.
8. **Interrupt setup.** `amdgpu_irq_init` → `pci_alloc_irq_vectors` → `bus_setup_intr` → `nmx_xnu_pci_irq_setup` (`xnu/nmx_pci.cpp:151-192`), which builds an `IOWorkLoop` + `IOInterruptEventSource` from inside the attach thread. Vector/index resolution (`interrupt_index`, `nmx_pci.cpp:118-133`) depends on the hypervisor presenting MSI-typed interrupt sources; a mismatch fails cleanly but leaves the GPU unusable, and a *stale* vector index would deliver to the wrong source.
9. **First BO / GART allocation.** `amdgpu_gem.o`/`amdgpu_ttm.o` → `linuxkpi_dma_alloc_noncoherent` (`override/src/linux_pci.c:2027-2049`, `kmem_alloc_contig`) and `bus_dmamem_alloc` (`nmx_busdma.c:247-278`) with the device's `lowaddr`. On an APU the coherent mask path (`linuxkpi_dmam_alloc_coherent`, `linux_pci.c:1999-2022`) is exercised; a failure is clean ENOMEM, but the subsequent `linux_dma_map_phys_common` pctrie insert (`linux_pci.c:1776-1820`) with `linux_dma_obj_zone` == NULL (if the SYSINIT at `linux_pci.c:1721` had not run) would NULL-deref — currently ordered correctly, keep it that way.
10. **kern_reboot / panic-on-purpose paths.** If amdgpu decides to reboot or hits a KASSERT during bring-up: `kern_reboot` → `panic` (`bsdcompat/src/nmx_misc.c:320-323`); the port's own invariant panics (`nmx_lock.c:47-300`, `nmx_malloc.c:161,258`, `linux_fpu.c:104`) execute constantly during attach — any of them firing on first load is by design a crash, not a decline.

---

## 4. Memory/DMA (nmx_busdma.c)

All bus_dma symbols referenced by the 902 built objects are defined in the port (`nm -u` over `obj/*.o`, `lkobj/*.o`, `xnuobj/*.o`): `__bus_dmamap_load_phys`, `_bus_dma_tag_create/destroy`, `_bus_dmamap_create/destroy/sync/unload`, `_bus_dmamem_alloc/free`, `_bus_dma_id_mapped` — every one implemented in `bsdcompat/src/nmx_busdma.c`. **No unimplemented op that would NULL-deref on the first BO allocation was found.**

Latent notes (P2):
- `bus_dmamap_load` (`nmx_busdma.c:176-214`) caps a buffer at 64 segments regardless of the tag's `nsegments` (up to 32k for TTM tags): a >64-segment buffer fails EFBIG instead of mapping — clean failure, but amdgpu S/G lists larger than 64 physical runs will fail where Linux succeeds.
- `bus_dmamap_sync` is a pure fence (`nmx_busdma.c:238-241`) — correct for coherent x86 PCIe and an APU whose GPU view goes through the same cache-coherent fabric, but wrong for the NPU case already documented in `nmx_page.c:690-701`.
- `bus_dma_id_mapped` short-circuits to identity when no IOMMU is active (`nmx_busdma.c:118-128`); on Reims (hypervisor without a visible IOMMU) all DMA is identity — fine for a VM, but means `lowaddr` limits are only enforced, never translated (by design, documented in the header comment).
- MSIX is unimplemented (`pci_alloc_msix` → `ENXIO`, `nmx_bus.c:999`); amdgpu MSI-X users (discrete GPUs with >32 vectors) fall back to MSI.

---

## 5. TODO/FIXME/panic/assert inventory on load/probe paths

Panics that execute on the load/attach path (all intentional invariant checks, but any firing = kernel panic):
- `bsdcompat/src/nmx_kernel.c:162` — thread-record alloc failure.
- `bsdcompat/src/nmx_lock.c:47,65,73,141,143,159,175,184,298,300` (+8) — mtx/sx misuse (init-before-use is exactly the init-order bug class audited in §2; these will catch it, fatally).
- `bsdcompat/src/nmx_malloc.c:161` — free() magic check, runs on *every* free during load; `:258` — alignment > page.
- `bsdcompat/src/nmx_misc.c:322` — `kern_reboot()` from driver code panics.
- `override/src/linux_fpu.c:104` — kernel FPU section without save areas (SYSINIT at `linux_fpu.c:83` runs before attach; malloc failure degrades to this panic).
- `override/src/linux_compat.c:191` — `panic_cmp` rb-tree comparator ("no cmp"), reached only if an interval tree is used without a comparator — latent.
- `override/src/linux_devres.c:80-269` — 8 KASSERTs on devres misuse, exercised by every `devm_*` call during attach.

TODO/FIXME/XXX in the port's own code (none in bsdcompat/, none crash the load path):
- `override/src/linux_compat.c:1036,1077` — "XXX no support for I/O vectors currently" (preadv/pwritev paths; GPU ioctl path does not use them).
- `override/src/linux_pci.c:1590` — "TODO PCI_IRQ_AFFINITY" (MSI affinity ignored; benign single-vector behaviour).
- `override/src/linux_pci.c:1685` — "TODO" stub; `:37,400,411,799` — informational XXXs from the FreeBSD fork.
- No TODO/FIXME markers exist in `bsdcompat/src/*.c` or `xnu/*.cpp`.

---

## Verdict summary

- 3 × P0, all in the bundle/identity layer (`kext/Info.plist` ↔ `xnu/nmx_kext.cpp` ↔ `link.sh`): kmod name, IOClass, opt-in knob names. Any one of them prevents the kext from ever driving a device; two of them prevent it from loading at all. These must be reconciled before the first load.
- 2 × P1: start() not gated on BARs/MSI (`nmx_kext.cpp:65-97`); interrupt-source availability in a VM (`nmx_bus.c:999`, `xnu/nmx_pci.cpp:135-192`).
- The runtime layer itself (init order, busdma, taskqueues, firmware, ACPI bridge) is internally consistent; the highest-risk *runtime* sites are the first MMIO/discovery/DCN paths of amdgpu on 780M (§3 items 2-7).

## Post-audit fixes (parent session, 2026-10-15)

- **P0-1/2/3 (bundle/kmod/IOClass/opt-in identity)**: RESOLVED by the Raphaeli rename. kmod `KMOD_EXPLICIT_DECL(me.tretrauit.raphaeli)` == `CFBundleIdentifier` == `IOClass Raphaeli` == C++ class `Raphaeli` (`__ZN8Raphaeli10gMetaClassE` exported); boot args `raphaeli-amd=1`/`raphaeli-intel=1`, device property `raphaeli-gpu`; personalities `Raphaeli780M`/`RaphaeliIntel`. Binary contains zero `NullMoth`/`NMXGPU`/`com.raphaeli` strings. Final: `out/Raphaeli.kext` sha256 `77dbc0bd…`, Mach-O 64-bit kext bundle x86_64.
- **P1-1 (start() not gated on BARs)**: FIXED — `Raphaeli::start()` now rejects devices with missing/zero-length/I/O-type BAR0 via `nmx_xnu_pci_bar_info(kIOPCIConfigBaseAddress0)` before port start; clean decline logs "no usable MMIO BAR0".
- **P2 (64-segment cap in `bus_dmamap_load`)**: FIXED — cap removed; `nmax` now honors the tag's own `nsegments` (up to 32k for TTM tags). Compiles clean (`ccsrc.sh` rc=0), relinked.
- **Validation**: `kmutil inspect -V tb -p out/Raphaeli.kext` OK (bundle structure validated against boot KC inventory). Full AuxKC link test requires a KDK for build 24G824 (Apple Developer download) — deferred to hardware bring-up; a `gen_ccdb.sh` was added emitting `compile_commands.json` for IDE analysis with the real port flags.
- **LSP dispositions**: clangd LSP on `nmx_busdma.c` confirmed clean after CCDB; `__atomic_thread_fence`/`__ATOMIC_SEQ_CST` flagged "reserved namespace" = false positive (C11 <stdatomic.h> API). `c-no-malloc-free` ast-grep warnings = the port's kernel allocator idiom; `mapp` typos = FreeBSD naming convention.
