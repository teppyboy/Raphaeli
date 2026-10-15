/*
 * Kernel-side scanout framebuffer allocator (the IOFramebuffer backing store) for Raphaeli.
 *
 * v0 allocates a physically contiguous run of wired system RAM and hands out both its physical
 * address (for the fb lane's user mappings and the CRTC's later use of the region) and a stable
 * write-combined kernel view. The pages themselves stay on the port's cached kernel mapping —
 * x86 PCIe display DMA snoops the CPU caches, so writes through either view reach the scanout.
 * The WC view is one extra mapping, not a cache-attribute change: a kext cannot retype an existing
 * kernel mapping on macOS (see the pmap_change_attr note in nmx_page.c), so the WC view is mapped
 * by physical address, exactly like a BAR (nmx_xnu_map_phys with kIOMapWriteCombineCache).
 *
 * The buffer is zeroed through the WC view itself: pages zeroed through the cached view would
 * leave dirty zero lines in the CPU caches, which WC stores do not flush (the same hazard
 * pmap_page_set_memattr guards against for the NPU).
 *
 * v1 (TODO, once fb-display's CRTC plumbing exists): allocate from the card's VRAM through the
 * TTM pool instead — ttm_pool_alloc_pages on the amdgpu GTT/VRAM move path (obj/ttm_*.o) already
 * knows how to carve scanout-usable ranges from the GTT aperture; then phys_addr becomes the
 * device-side (BAR) address, kern_addr maps it with NMX_CACHE_WC, and nothing here changes shape.
 *
 * Prototypes come from the lane contract (docs/display-accel-contract.md); fb-display declares
 * them in its own nmx_fb_internal.h, so both sides must keep these exact signatures.
 */
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/lock.h>
#include <sys/mutex.h>
#include <vm/vm.h>
#include <vm/vm_extern.h>
#include <vm/pmap.h>
#include <mach/kern_return.h>
#include "nmx_xnu.h"

#define NMX_SCANOUT_MAX_SIZE ((size_t)512 << 20)        /* a mode-setting bug asking for 4 GB must fail, not hang */
#define NMX_SCANOUT_SLOTS 8                             /* one framebuffer per display head; plenty for v0 */

struct nmx_scanout {
    vm_offset_t pa;                 /* physical address of the run (the lookup key) */
    vm_size_t size;                 /* rounded size */
    void *wb_kva;                   /* the allocation's own (cached) kernel mapping; what kmem_free takes back */
    void *wc_kva;                   /* the WC view handed out as kern_addr */
};

static struct nmx_scanout nmx_scanouts[NMX_SCANOUT_SLOTS];
static struct mtx nmx_scanout_mtx;
MTX_SYSINIT(nmx_scanout, &nmx_scanout_mtx, "scanout allocations", MTX_DEF);

kern_return_t nmx_scanout_alloc(size_t size, vm_offset_t *phys_addr,
                                vm_offset_t *kern_addr, vm_size_t *mapped)
{
    if (phys_addr == NULL || kern_addr == NULL || mapped == NULL)
        return KERN_INVALID_ARGUMENT;
    *phys_addr = 0;
    *kern_addr = 0;
    *mapped = 0;
    if (size == 0 || size > NMX_SCANOUT_MAX_SIZE)
        return KERN_INVALID_ARGUMENT;
    vm_size_t len = round_page(size);
    if (len < size)
        return KERN_INVALID_ARGUMENT;       /* rounding overflowed */

    /* contiguous, page-aligned, wired; below 4 GB so a 32-bit-minded scanout engine can reach it */
    void *wb = kmem_alloc_contig(len, M_NOWAIT, 0, 0xFFFFFFFFULL, PAGE_SIZE, 0, VM_MEMATTR_WRITE_COMBINING);
    if (wb == NULL)
        return KERN_NO_SPACE;
    vm_offset_t pa = nmx_kva_to_phys(wb);
    void *wc = pmap_mapdev_attr(pa, len, VM_MEMATTR_WRITE_COMBINING);
    if (wc == NULL || pa == 0) {
        kmem_free(wb, len);
        return KERN_NO_SPACE;
    }
    memset(wc, 0, len);

    kern_return_t kr = KERN_NO_SPACE;
    mtx_lock(&nmx_scanout_mtx);
    for (int i = 0; i < NMX_SCANOUT_SLOTS; i++) {
        if (nmx_scanouts[i].pa != 0)
            continue;
        nmx_scanouts[i].pa = pa;
        nmx_scanouts[i].size = len;
        nmx_scanouts[i].wb_kva = wb;
        nmx_scanouts[i].wc_kva = wc;
        kr = KERN_SUCCESS;
        break;
    }
    mtx_unlock(&nmx_scanout_mtx);
    if (kr != KERN_SUCCESS) {
        pmap_unmapdev(wc, len);
        kmem_free(wb, len);
    }
    return kr;
}

kern_return_t nmx_scanout_free(vm_offset_t phys_addr, vm_size_t mapped)
{
    mtx_lock(&nmx_scanout_mtx);
    for (int i = 0; i < NMX_SCANOUT_SLOTS; i++) {
        struct nmx_scanout *s = &nmx_scanouts[i];
        if (s->pa == 0 || s->pa != phys_addr)
            continue;
        if (s->size != mapped) {
            mtx_unlock(&nmx_scanout_mtx);
            return KERN_INVALID_ARGUMENT;   /* not the size this allocation was made with */
        }
        pmap_unmapdev(s->wc_kva, s->size);
        kmem_free(s->wb_kva, s->size);
        memset(s, 0, sizeof(*s));
        mtx_unlock(&nmx_scanout_mtx);
        return KERN_SUCCESS;
    }
    mtx_unlock(&nmx_scanout_mtx);
    return KERN_INVALID_ARGUMENT;
}
