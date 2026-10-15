/*
 * The accel lane's ring/fence bridge, amdgpu side: the real path behind the IOGraphicsAccelerator2
 * submit hooks (nmx_xnu_accel_ring_submit / nmx_xnu_accel_fence_wait, Kernel/nmx_accel.cpp). The IOKit
 * side compiles against Apple's headers only, so its hooks delegate through nmx_port.h to here, which
 * sees the driver.
 *
 * A submit is one kernel-internal IB schedule on a gfx ring — amdgpu_ib_schedule with no job and no VM,
 * the exact shape of amdgpu's own ring tests — pointing the ring at an indirect buffer the caller wrote
 * ('ib_addr', a GPU address; 'ib_dw' its length in dwords), and returns the schedule's dma_fence as an
 * opaque handle. A wait is dma_fence_wait_timeout on such a fence (the handle is consumed: one wait per
 * fence). Unknown ring, uninitialized or suspended device, detached driver: refused with an errno, the
 * hooks map that to KERN_*. Nothing here panics.
 *
 * v1: one GPU — the device the kext registered last (nmx_accel_bridge_device) is served.
 */
#include <linux/kernel.h>
#include <linux/pci.h>
#include <linux/dma-fence.h>
#include <linux/jiffies.h>
#include <linux/string.h>
#include <string.h>

#include <drm/drm_device.h>
#include <drm/drm_drv.h>

#include <sys/param.h>
#include <sys/systm.h>
#include <mach/kern_return.h>
#include <pexpert/pexpert.h>
#include <sys/malloc.h>
#include <sys/bus.h>

#include "amdgpu.h"
#include "soc15d.h"

#include "nmx_port.h"

/* the GPU whose driver the hooks serve (set by the kext once its driver attached the device) */
static void *g_iopci;

kern_return_t nmx_xnu_accel_ring_submit(uint32_t ring, uint64_t ib_addr, uint32_t ib_dw,
                                        uint64_t *fence_out);
kern_return_t nmx_xnu_accel_fence_wait(uint64_t fence, uint32_t timeout_ms);

/* the amdgpu_device of the attached driver on 'iopci', or NULL (same walk as nmx_fb_bridge.c) */
static struct amdgpu_device *adev_of(void *iopci)
{
    device_t dev = nmx_device_for_pci(iopci);
    device_t *kids = NULL;
    int n = 0;
    struct amdgpu_device *adev = NULL;
    if (dev == NULL || device_get_children(dev, &kids, &n) != 0)
        return NULL;
    for (int i = 0; i < n && adev == NULL; i++) {
        if (!device_is_attached(kids[i]))
            continue;
        struct pci_dev *pdev = device_get_softc(kids[i]);
        struct drm_device *drm = pdev != NULL ? pci_get_drvdata(pdev) : NULL;
        if (drm != NULL && drm->driver != NULL && drm->driver->name != NULL &&
            strcmp(drm->driver->name, "amdgpu") == 0)
            adev = drm_to_adev(drm);
    }
    free(kids, M_TEMP);
    return adev;
}

void nmx_accel_bridge_device(void *iopci)
{
    struct amdgpu_device *adev = adev_of(iopci);
    if (adev == NULL)
        return;
    if (g_iopci != NULL && g_iopci != iopci)
        printf("Raphaeli accel bridge: another GPU registered; the hooks serve one device (v1)\n");
    g_iopci = iopci;
    printf("Raphaeli accel bridge: serving %u gfx ring(s) (v1)\n", adev->gfx.num_gfx_rings);
}

int nmx_accel_bridge_submit(uint32_t ring, uint64_t ib_addr, uint32_t ib_dw, uint64_t *fence_out)
{
    if (fence_out)
        *fence_out = 0;
    if (ib_addr == 0 || ib_dw == 0)
        return -EINVAL;
    struct amdgpu_device *adev = g_iopci != NULL ? adev_of(g_iopci) : NULL;
    if (adev == NULL || !adev->accel_working)
        return -ENODEV;
    if (adev->in_suspend || adev->shutdown)
        return -EBUSY;
    if (ring >= adev->gfx.num_gfx_rings)
        return -EINVAL;
    struct amdgpu_ring *gring = &adev->gfx.gfx_ring[ring];
    /* the IB at ib_addr is the caller's; only the schedule's own fence is returned (one reference) */
    struct amdgpu_ib ib;
    memset(&ib, 0, sizeof(ib));
    ib.gpu_addr = ib_addr;
    ib.length_dw = ib_dw;
    struct dma_fence *f = NULL;
    int r = amdgpu_ib_schedule(gring, 1, &ib, NULL, &f);
    if (r)
        return r;
    if (fence_out)
        *fence_out = (uint64_t)(uintptr_t)f;
    else
        dma_fence_put(f);
    return 0;
}

int nmx_accel_bridge_fence_wait(uint64_t fence, uint32_t timeout_ms)
{
    struct dma_fence *f = (struct dma_fence *)(uintptr_t)fence;
    if (f == NULL)
        return -EINVAL;
    signed long left =
        dma_fence_wait_timeout(f, false, timeout_ms != 0 ? msecs_to_jiffies(timeout_ms) : 0);
    dma_fence_put(f);
    return left < 0 ? (int)left : 0;
}

/*
 * Boot-arg selftest (raphaeli-accel-test=1), called once after the driver attached (nmx_kext.cpp,
 * Raphaeli::attachNow): two PACKET3 NOPs in a GTT buffer go through the accel hooks onto gfx ring 0,
 * the fence is waited on and the result logged. A failure leaves nothing behind and cannot affect the
 * driver; without the boot argument this does nothing.
 */
int nmx_accel_selftest(void)
{
    int on = 0;
    if (!PE_parse_boot_argn("raphaeli-accel-test", &on, sizeof(on)) || on == 0)
        return 0;
    struct amdgpu_device *adev = g_iopci != NULL ? adev_of(g_iopci) : NULL;
    if (adev == NULL) {
        printf("Raphaeli accel selftest: no driver device; skipped\n");
        return 0;
    }
    struct amdgpu_bo *bo = NULL;
    u64 gpu_addr = 0;
    void *cpu = NULL;
    int r = amdgpu_bo_create_kernel(adev, 4096, 4096, AMDGPU_GEM_DOMAIN_GTT, &bo, &gpu_addr, &cpu);
    if (r) {
        printf("Raphaeli accel selftest: no IB buffer (%d)\n", r);
        return r;
    }
    uint32_t *ib = cpu;
    ib[0] = PACKET3(PACKET3_NOP, 0);
    ib[1] = PACKET3(PACKET3_NOP, 0);
    uint64_t fence = 0;
    kern_return_t kr = nmx_xnu_accel_ring_submit(0, gpu_addr, 2, &fence);
    if (kr != KERN_SUCCESS) {
        printf("Raphaeli accel selftest: submit refused (0x%x)\n", kr);
        r = -1;
    } else {
        kr = nmx_xnu_accel_fence_wait(fence, 5000);
        printf("Raphaeli accel selftest: gfx ring 0 NOP IB submitted, fence %s (0x%x)\n",
               kr == KERN_SUCCESS ? "signaled: PASS" : "NOT signaled: FAIL", kr);
        r = kr == KERN_SUCCESS ? 0 : -1;
    }
    amdgpu_bo_free_kernel(&bo, &gpu_addr, &cpu);
    return r;
}
