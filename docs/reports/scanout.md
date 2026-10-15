# Scanout lane report — kernel-side display framebuffer allocator (Raphaeli/xkpi)

Lane: scanout (owns `xkpi/bsdcompat/src/nmx_scanout.c`, `xkpi/override/display/**`; did not touch xnu/, Info.plist, link.sh)

## What was built

`nmx_scanout_alloc(size, &pa, &kva, &mapped)` / `nmx_scanout_free(pa, mapped)` with the exact
contract signatures from `docs/display-accel-contract.md`.

### Design — v0 (system RAM, WC-backed)

1. **Sanitize**: size must be > 0 and ≤ 512 MB, page-rounded (`round_page`), overflow-checked.
2. **Allocate**: `kmem_alloc_contig(len, M_NOWAIT, 0, 0xFFFFFFFFULL, PAGE_SIZE, 0, VM_MEMATTR_WRITE_COMBINING)`
   — one physically contiguous run of wired system RAM below 4 GB (a 32-bit-minded scanout engine
   can reach it), aligned to one page. Pages carry the WC `pat_mode` record so any later user
   mapping that honors page attributes (LinuxKPI vmap / fb lane) stays consistent.
3. **WC kernel view**: a kext cannot retype an existing kernel mapping's cache mode on macOS
   (`pmap_change_attr` is a no-op here — see the comment in `nmx_page.c`), so the WC view is a
   second mapping by physical address: `pmap_mapdev_attr(pa, len, VM_MEMATTR_WRITE_COMBINING)`,
   which is `nmx_xnu_map_phys` (IOMemoryDescriptor::withPhysicalAddress +
   `kIOMapWriteCombineCache`) — the same pattern the port already uses for BAR0 and pmap_mapdev.
4. **Zero through the WC view** (`memset(wc, 0, len)`), not through the cached view: pages zeroed
   via the WB view leave dirty zero lines in the CPU caches that WC stores do not flush (the exact
   hazard `pmap_page_set_memattr` documents for the NPU). x86 PCIe display DMA snoops the caches,
   so CRTC reads see the zeros either way; zeroing via WC makes both views identical from birth.
5. **Bookkeeping**: a static 8-slot table (mutex via `MTX_SYSINIT`) keyed by physical address holds
   `{pa, size, wb_kva, wc_kva}`. The contract's free signature carries no kernel address, so
   `nmx_scanout_free` looks the entry up by `phys_addr` (rejects wrong `mapped` size), unmaps the
   WC view (`pmap_unmapdev`) and frees the run (`kmem_free`). 8 slots ≈ one framebuffer per head.
   Exhaustion of slots or of contiguous RAM returns `KERN_NO_SPACE`; bad arguments return
   `KERN_INVALID_ARGUMENT` and never partial state.

### v1 hook — VRAM

The allocation is one call site. When fb-display's CRTC plumbing exists, switch the body to the
TTM pool (`ttm_pool_alloc_pages` path already compiled in `obj/ttm_*.o`; amdguo object layer under
`kpi/drm-kmod/drivers/gpu/drm/amd`): allocate VRAM pages, `phys_addr` becomes the device-side
(BAR/aperture) address, `kern_addr` comes from `nmx_xnu_map_pages(pages, n, NMX_CACHE_WC, …)`
(vmap of scattered pages exists in `xnu/nmx_vm.cpp`), and the free path releases the pages instead
of `kmem_free`. Signature, table and zeroing logic are unchanged; the TODO is marked in the source
header.

## Userland mapping story (documented, no code needed)

- **GEM/TTM objects**: the DRM port already exposes kernel objects to userland —
  `override/src/nmx_linux_cdev.c` runs the driver's own `f_op->mmap` + fault handlers over a port
  owned `vm_area_struct` (fault inserts via `nmx_umap_insert` / `vmf_insert_pfn_prot` in the
  linux_page.c fork), including ttm-backed objects. DRM_IOCTL_MODE_MAP_DUMB style offsets ride the
  same path. Nothing to extend for GEM buffers; WC-ness follows the object's page attributes
  (`pmap_page_set_memattr`), already set by the amdgpu helpers.
- **The scanout buffer itself** (allocated by `nmx_scanout_alloc`, not a GEM object): fb-display
  exposes it through its IOFramebuffer user-client mapping — build
  `IOMemoryDescriptor::withPhysicalAddress(pa, size, kIODirectionInOut)` and
  `createMappingInTask(clientTask, 0, kIOMapAnywhere | kIOMapWriteCombineCache)` (mirrors
  `nmx_xnu_map_phys` but into the client's task). `phys_addr` from the contract is exactly what
  that call needs. No scanout-lane code is required.

## Self-check

`override/display/nmx_scanout_selftest.c`: `nmx_scanout_selftest()` — inert (returns 0) unless
boot-arg `raphaeli-scanout-test=1`; then allocates one 1920×1080×4 frame, fills a sparse pattern
through the WC view, verifies it, frees it, logs PASS/FAIL via `printf`. It cannot run "on load"
by itself: kexts run no C constructors under `-fapple-kext`, so integration must call
`nmx_scanout_selftest()` once (one line) from `Raphaeli::start()` after `nmx_port_start()`.

## Link/integration needs (exact, for the integration lane)

- `nmx_scanout.o` and `nmx_scanout_selftest.o` are built by `ccsrc.sh` into `srcobj/`, which
  link.sh already globs — **no link.sh edit is required**.
- One line in `xnu/nmx_kext.cpp` (kext lane) somewhere after `nmx_port_start()` succeeds:
  `extern int nmx_scanout_selftest(void); … nmx_scanout_selftest();`
- fb lane declares the two prototypes (already specified in the lane contract) and calls
  `nmx_scanout_alloc` before publishing RaphaeliFB (its gate mirrors the BAR0 check).

## Environment notes / risks

- `kpi/drm-kmod` and `kpi/freebsd-src` were **broken symlinks** (pointed at `../../research/*`,
  one level short of `../research/*`). Fixed locally to `../research/…` so the file compiles; the
  tracked symlink blobs still hold the wrong target — whoever commits next should fix them (one
  `ln -s` each, or fix the committed blobs). Without it nothing in xkpi compiles.
- Risk: `KERN_NO_SPACE` (no contiguous 8 MB+ run under 4 GB after boot fragmentation) —
  IOFramebuffer start fails cleanly per the safety invariant; v1 VRAM removes this class.
- Risk: dual view (WB `wb_kva` + WC `wc_kva`) of the same pages is intentional (free needs the
  allocation view); the WC view is what fb writes through, the WB view is never used for pixel data.
- Not checked: runtime behavior on hardware (no kernel execution possible here); MTX_SYSINIT lock
  follows the existing devmap pattern (`MTX_DEF`, sleepable context only — alloc/free are called
  from IOService start/stop, which sleep; not from interrupt context).
