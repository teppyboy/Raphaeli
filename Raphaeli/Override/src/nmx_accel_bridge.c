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
#include <linux/mutex.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <string.h>

#include <drm/drm_device.h>
#include <drm/drm_drv.h>
#include <drm/drm_exec.h>

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

/* VM and BO registries are bridge ownership boundaries: raw client integers never reach amdgpu unchecked. */
static DEFINE_MUTEX(g_vm_lock);
struct nmx_accel_bo_record {
    struct amdgpu_bo *bo;
    struct amdgpu_device *adev;
    uint64_t size;
    struct nmx_accel_bo_record *next;
};
static DEFINE_MUTEX(g_bo_lock);
static struct nmx_accel_bo_record *g_bos;
static bool nmx_accel_bridge_bo_is_mapped(struct amdgpu_bo *bo);

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

/*
 * The memory plane: one pinned kernel GEM BO per vendor video-memory object (RaphaeliVidMemory),
 * created with amdgpu's own kernel helper — the same shape the selftest's IB buffer uses. The BO is
 * pinned, so its device address is stable; v0 stops there (no GPU page tables yet, so nothing maps
 * these bytes into GPU VM — that is the next lane).
 */
int nmx_accel_bridge_alloc(uint64_t size, uint64_t align, uint32_t domain, uint64_t *bo_out,
                           uint64_t *gpu_addr_out, void **cpu_out)
{
    if (bo_out)
        *bo_out = 0;
    if (gpu_addr_out)
        *gpu_addr_out = 0;
    if (cpu_out)
        *cpu_out = NULL;
    if (size == 0 || bo_out == NULL)
        return -EINVAL;
    struct amdgpu_device *adev = g_iopci != NULL ? adev_of(g_iopci) : NULL;
    if (adev == NULL || !adev->accel_working)
        return -ENODEV;
    if (adev->in_suspend || adev->shutdown)
        return -EBUSY;

    struct nmx_accel_bo_record *record = kzalloc(sizeof(*record), GFP_KERNEL);
    if (record == NULL)
        return -ENOMEM;
    struct amdgpu_bo *bo = NULL;
    u64 addr = 0;
    void *cpu = NULL;
    int r = amdgpu_bo_create_kernel(adev, size, align != 0 ? (int)align : 4096, domain, &bo, &addr, &cpu);
    if (r) {
        kfree(record);
        return r;
    }
    record->bo = bo;
    record->adev = adev;
    record->size = amdgpu_bo_size(bo);
    mutex_lock(&g_bo_lock);
    record->next = g_bos;
    g_bos = record;
    mutex_unlock(&g_bo_lock);
    *bo_out = (uint64_t)(uintptr_t)bo;
    if (gpu_addr_out)
        *gpu_addr_out = addr;
    if (cpu_out)
        *cpu_out = cpu;
    return 0;
}

uint64_t nmx_accel_bridge_dmap(uint64_t bo)
{
    struct amdgpu_bo *b = (struct amdgpu_bo *)(uintptr_t)bo;
    if (b == NULL)
        return 0;
    mutex_lock(&g_bo_lock);
    struct nmx_accel_bo_record *record = g_bos;
    while (record != NULL && record->bo != b)
        record = record->next;
    uint64_t addr = record != NULL ? amdgpu_bo_gpu_offset(b) : 0;
    mutex_unlock(&g_bo_lock);
    return addr;
}

int nmx_accel_bridge_free(uint64_t bo, uint64_t gpu_addr, void *cpu)
{
    struct amdgpu_bo *b = (struct amdgpu_bo *)(uintptr_t)bo;
    if (b == NULL)
        return 0;
    /* Free takes the same outer lock as mapping, so a BO cannot disappear under a VM operation. */
    mutex_lock(&g_vm_lock);
    mutex_lock(&g_bo_lock);
    struct nmx_accel_bo_record **link = &g_bos;
    while (*link != NULL && (*link)->bo != b)
        link = &(*link)->next;
    struct nmx_accel_bo_record *record = *link;
    if (record == NULL) {
        mutex_unlock(&g_bo_lock);
        mutex_unlock(&g_vm_lock);
        return -EINVAL;
    }
    if (nmx_accel_bridge_bo_is_mapped(b)) {
        mutex_unlock(&g_bo_lock);
        mutex_unlock(&g_vm_lock);
        return -EBUSY;
    }
    if (amdgpu_bo_reserve(b, true) != 0) {
        mutex_unlock(&g_bo_lock);
        mutex_unlock(&g_vm_lock);
        return -EBUSY;
    }
    *link = record->next;
    mutex_unlock(&g_bo_lock);
    mutex_unlock(&g_vm_lock);
    /* always: amdgpu_bo_create_kernel kmaps the BO; pinned amdgpu_bo_kunmap is a no-op without a kmap */
    amdgpu_bo_kunmap(b);
    amdgpu_bo_unpin(b);
    amdgpu_bo_unreserve(b);
    amdgpu_bo_unref(&b);
    kfree(record);
    (void)gpu_addr;
    (void)cpu;
    return 0;
}

int nmx_accel_bridge_fence_wait(uint64_t fence, uint32_t timeout_ms)
{
    struct dma_fence *f = (struct dma_fence *)(uintptr_t)fence;
    if (f == NULL)
        return -EINVAL;
    signed long left =
        dma_fence_wait_timeout(f, false, timeout_ms != 0 ? msecs_to_jiffies(timeout_ms) : 0);
    int status = left > 0 ? dma_fence_get_status(f) : 0;
    dma_fence_put(f);
    if (left < 0)
        return (int)left;
    if (left == 0 || status == 0)
        return -ETIME;
    return status < 0 ? status : 0;
}

/*
 * Per-task GPU VM: a bridge-owned record around one amdgpu_vm, created with amdgpu_vm_init and released by destroy or
 * by nmx_accel_bridge_vm_release_all (called from nmx_port_detach before the driver detaches). The handle is the record's
 * address; only live records are in the registry, so an unknown or repeated handle is refused without touching amdgpu.
 * shortcut: no PASID is allocated (the open path's amdgpu_pasid_alloc + amdgpu_vm_set_pasid), so GPU faults cannot be
 * attributed to a task; upgrade with task fault identity. shortcut: release-all frees every record on any port detach,
 * correct while v1 serves one GPU; upgrade by matching records to the detaching device. */
struct nmx_accel_vm_bo;
struct nmx_accel_vm_mapping {
    struct nmx_accel_vm_bo *vm_bo;
    uint64_t va;
    uint64_t size;
    struct nmx_accel_vm_mapping *next;
};
struct nmx_accel_vm_bo {
    struct nmx_accel_bo_record *bo;
    struct amdgpu_bo_va *bo_va;
    struct nmx_accel_vm_mapping *mappings;
    struct nmx_accel_vm_bo *next;
};
struct nmx_accel_vm {
    struct amdgpu_device *adev;
    struct amdgpu_vm vm;
    struct nmx_accel_vm *next;
    struct nmx_accel_vm_bo *bos;
};
static struct nmx_accel_vm *g_vms;

static int nmx_accel_vm_update(struct nmx_accel_vm *vm, struct nmx_accel_vm_bo *vm_bo,
                               bool map)
{
    int r;
    if (!amdgpu_vm_ready(&vm->vm))
        return 0;
    r = amdgpu_vm_clear_freed(vm->adev, &vm->vm, NULL);
    if (r)
        return r;
    if (map) {
        r = amdgpu_vm_bo_update(vm->adev, vm_bo->bo_va, false);
        if (r)
            return r;
    }
    return amdgpu_vm_update_pdes(vm->adev, &vm->vm, false);
}

static bool nmx_accel_bridge_bo_is_mapped(struct amdgpu_bo *bo)
{
    struct nmx_accel_vm *vm;
    for (vm = g_vms; vm != NULL; vm = vm->next) {
        struct nmx_accel_vm_bo *vm_bo;
        for (vm_bo = vm->bos; vm_bo != NULL; vm_bo = vm_bo->next) {
            if (vm_bo->bo->bo == bo && vm_bo->mappings != NULL)
                return true;
        }
    }
    return false;
}

static void nmx_accel_vm_fini(struct nmx_accel_vm *vm)
{
    struct drm_exec exec;
    int r = 0;

    drm_exec_init(&exec, DRM_EXEC_INTERRUPTIBLE_WAIT | DRM_EXEC_IGNORE_DUPLICATES, 0);
    drm_exec_until_all_locked(&exec) {
        struct nmx_accel_vm_bo *entry;
        for (entry = vm->bos; entry != NULL; entry = entry->next) {
            r = drm_exec_lock_obj(&exec, &entry->bo->bo->tbo.base);
            drm_exec_retry_on_contention(&exec);
            if (r)
                goto out;
        }
        r = amdgpu_vm_lock_pd(&vm->vm, &exec, 2);
        drm_exec_retry_on_contention(&exec);
        if (r)
            goto out;
    }
    if (r)
        goto out;

    /* bo_del removes all VM intervals; vm_fini then frees its page tables safely. */
    while (vm->bos != NULL) {
        struct nmx_accel_vm_bo *entry = vm->bos;
        vm->bos = entry->next;
        amdgpu_vm_bo_del(vm->adev, entry->bo_va);
        while (entry->mappings != NULL) {
            struct nmx_accel_vm_mapping *mapping = entry->mappings;
            entry->mappings = mapping->next;
            kfree(mapping);
        }
        kfree(entry);
    }
out:
    drm_exec_fini(&exec);
    amdgpu_vm_fini(vm->adev, &vm->vm);
    kfree(vm);
}

/* unlinks the live record whose handle is 'handle' (caller holds g_vm_lock); NULL when there is none */
static struct nmx_accel_vm *nmx_accel_vm_unlink(uint64_t handle)
{
    struct nmx_accel_vm **link = &g_vms;
    while (*link != NULL && (uint64_t)(uintptr_t)*link != handle)
        link = &(*link)->next;
    struct nmx_accel_vm *vm = *link;
    if (vm != NULL)
        *link = vm->next;
    return vm;
}

int nmx_accel_bridge_vm_create(uint64_t *vm_out)
{
    if (vm_out == NULL)
        return -EINVAL;
    *vm_out = 0;
    struct amdgpu_device *adev = g_iopci != NULL ? adev_of(g_iopci) : NULL;
    if (adev == NULL || !adev->accel_working)
        return -ENODEV;
    if (adev->in_suspend || adev->shutdown)
        return -EBUSY;
    struct nmx_accel_vm *vm = kzalloc(sizeof(*vm), GFP_KERNEL);
    if (vm == NULL)
        return -ENOMEM;
    /* the KMS open path's XCP value: NO_PARTITION only when a partition manager exists, else 0 (amdgpu_xcp.c) */
    int32_t xcp_id = adev->xcp_mgr != NULL ? AMDGPU_XCP_NO_PARTITION : 0;
    int r = amdgpu_vm_init(adev, &vm->vm, xcp_id);
    if (r) {
        kfree(vm);
        return r;
    }
    vm->adev = adev;
    mutex_lock(&g_vm_lock);
    vm->next = g_vms;
    g_vms = vm;
    mutex_unlock(&g_vm_lock);
    *vm_out = (uint64_t)(uintptr_t)vm;
    return 0;
}

/* no device gate: teardown must still release the VM while the device shuts down */
int nmx_accel_bridge_vm_destroy(uint64_t vm)
{
    /* the VM's bo_va entries are torn down under g_bo_lock, so a concurrent free sees the BO still mapped or gone */
    mutex_lock(&g_vm_lock);
    mutex_lock(&g_bo_lock);
    struct nmx_accel_vm *rec = nmx_accel_vm_unlink(vm);
    if (rec != NULL)
        nmx_accel_vm_fini(rec);
    mutex_unlock(&g_bo_lock);
    mutex_unlock(&g_vm_lock);
    return rec != NULL ? 0 : -EINVAL;
}

/* port detach, before the driver detaches: every record is released while its amdgpu_device is still live */
void nmx_accel_bridge_vm_release_all(void)
{
    mutex_lock(&g_vm_lock);
    mutex_lock(&g_bo_lock);
    struct nmx_accel_vm *vms = g_vms;
    g_vms = NULL;
    while (vms != NULL) {
        struct nmx_accel_vm *next = vms->next;
        nmx_accel_vm_fini(vms);
        vms = next;
    }
    mutex_unlock(&g_bo_lock);
    mutex_unlock(&g_vm_lock);
}

/* device gates shared by map/unmap, in the order the client path requires (no amdgpu call) */
static int nmx_accel_bridge_vm_gate(struct amdgpu_device **adev_out)
{
    struct amdgpu_device *adev = g_iopci != NULL ? adev_of(g_iopci) : NULL;
    if (adev == NULL || !adev->accel_working)
        return -ENODEV;
    if (adev->in_suspend || adev->shutdown)
        return -EBUSY;
    *adev_out = adev;
    return 0;
}

/* pinned amdgpu_gem.c / amdgpu_vm_verify_parameters rules: page-aligned, nonzero size, no overflow, reserved bottom
 * and top, GMC hole, last page below max_pfn (no amdgpu call) */
static int nmx_accel_bridge_vm_check_range(struct amdgpu_device *adev, uint64_t va, uint64_t offset, uint64_t size)
{
    if (size == 0 || ((va | offset | size) & AMDGPU_GPU_PAGE_MASK))
        return -EINVAL;
    if (offset > ~(uint64_t)0 - size || va > ~(uint64_t)0 - size)
        return -EINVAL;
    if (va < AMDGPU_VA_RESERVED_BOTTOM)
        return -EINVAL;
    if (va < AMDGPU_GMC_HOLE_END && va + size > AMDGPU_GMC_HOLE_START)
        return -EINVAL;
    if (va + size > (adev->vm_manager.max_pfn << AMDGPU_GPU_PAGE_SHIFT) - AMDGPU_VA_RESERVED_TOP)
        return -EINVAL;
    return 0;
}

static struct nmx_accel_vm *nmx_accel_vm_find_locked(uint64_t handle)
{
    struct nmx_accel_vm *vm;
    for (vm = g_vms; vm != NULL; vm = vm->next) {
        if ((uint64_t)(uintptr_t)vm == handle)
            return vm;
    }
    return NULL;
}

static struct nmx_accel_bo_record *nmx_accel_bo_find_locked(uint64_t handle)
{
    struct amdgpu_bo *bo = (struct amdgpu_bo *)(uintptr_t)handle;
    struct nmx_accel_bo_record *record;
    for (record = g_bos; record != NULL; record = record->next) {
        if (record->bo == bo)
            return record;
    }
    return NULL;
}

static struct nmx_accel_vm_bo *nmx_accel_vm_bo_find_locked(struct nmx_accel_vm *vm,
                                                            struct nmx_accel_bo_record *bo)
{
    struct nmx_accel_vm_bo *entry;
    for (entry = vm->bos; entry != NULL; entry = entry->next) {
        if (entry->bo == bo)
            return entry;
    }
    return NULL;
}

static struct nmx_accel_vm_mapping *nmx_accel_vm_mapping_find_locked(struct nmx_accel_vm_bo *vm_bo,
                                                                       uint64_t va,
                                                                       uint64_t size)
{
    struct nmx_accel_vm_mapping *mapping;
    for (mapping = vm_bo->mappings; mapping != NULL; mapping = mapping->next) {
        if (mapping->va == va && mapping->size == size)
            return mapping;
    }
    return NULL;
}

static int nmx_accel_bridge_vm_lock(struct nmx_accel_vm *vm, struct nmx_accel_bo_record *bo,
                                    struct drm_exec *exec)
{
    int r;
    drm_exec_init(exec, DRM_EXEC_INTERRUPTIBLE_WAIT | DRM_EXEC_IGNORE_DUPLICATES, 0);
    drm_exec_until_all_locked(exec) {
        r = drm_exec_lock_obj(exec, &bo->bo->tbo.base);
        drm_exec_retry_on_contention(exec);
        if (r)
            return r;
        r = amdgpu_vm_lock_pd(&vm->vm, exec, 2);
        drm_exec_retry_on_contention(exec);
        if (r)
            return r;
    }
    return 0;
}

int nmx_accel_bridge_vm_map(uint64_t vm_handle, uint64_t bo_handle, uint64_t va,
                            uint64_t offset, uint64_t size, uint64_t flags)
{
    struct amdgpu_device *adev = NULL;
    struct nmx_accel_vm *vm;
    struct nmx_accel_bo_record *bo;
    struct nmx_accel_vm_bo *vm_bo;
    struct nmx_accel_vm_mapping *mapping;
    struct drm_exec exec;
    bool added = false;
    int r = nmx_accel_bridge_vm_gate(&adev);
    if (r)
        return r;
    if (vm_handle == 0 || bo_handle == 0)
        return -EINVAL;
    r = nmx_accel_bridge_vm_check_range(adev, va, offset, size);
    if (r)
        return r;

    mutex_lock(&g_vm_lock);
    vm = nmx_accel_vm_find_locked(vm_handle);
    if (vm == NULL || vm->adev != adev) {
        mutex_unlock(&g_vm_lock);
        return -EINVAL;
    }
    mutex_lock(&g_bo_lock);
    bo = nmx_accel_bo_find_locked(bo_handle);
    if (bo == NULL || bo->adev != adev || offset > bo->size || size > bo->size - offset) {
        mutex_unlock(&g_bo_lock);
        mutex_unlock(&g_vm_lock);
        return -EINVAL;
    }
    mapping = kzalloc(sizeof(*mapping), GFP_KERNEL);
    if (mapping == NULL) {
        mutex_unlock(&g_bo_lock);
        mutex_unlock(&g_vm_lock);
        return -ENOMEM;
    }
    r = nmx_accel_bridge_vm_lock(vm, bo, &exec);
    if (r) {
        drm_exec_fini(&exec);
        goto map_out;
    }
    vm_bo = nmx_accel_vm_bo_find_locked(vm, bo);
    if (vm_bo == NULL) {
        vm_bo = kzalloc(sizeof(*vm_bo), GFP_KERNEL);
        if (vm_bo == NULL) {
            r = -ENOMEM;
            goto map_unlock;
        }
        vm_bo->bo = bo;
        vm_bo->bo_va = amdgpu_vm_bo_add(adev, &vm->vm, bo->bo);
        if (vm_bo->bo_va == NULL) {
            kfree(vm_bo);
            r = -ENOMEM;
            goto map_unlock;
        }
        added = true;
    }
    r = amdgpu_vm_bo_map(adev, vm_bo->bo_va, va, offset, size, flags);
    if (r)
        goto map_remove;
    r = nmx_accel_vm_update(vm, vm_bo, true);
    if (r)
        goto map_unmap;
    mapping->vm_bo = vm_bo;
    mapping->va = va;
    mapping->size = size;
    mapping->next = vm_bo->mappings;
    vm_bo->mappings = mapping;
    mapping = NULL;
    if (added) {
        vm_bo->next = vm->bos;
        vm->bos = vm_bo;
    }
    goto map_unlock;
map_unmap:
    amdgpu_vm_bo_unmap(adev, vm_bo->bo_va, va);
    nmx_accel_vm_update(vm, vm_bo, false);
map_remove:
    if (added) {
        amdgpu_vm_bo_del(adev, vm_bo->bo_va);
        kfree(vm_bo);
    }
map_unlock:
    drm_exec_fini(&exec);
map_out:
    kfree(mapping);
    mutex_unlock(&g_bo_lock);
    mutex_unlock(&g_vm_lock);
    return r;
}

int nmx_accel_bridge_vm_unmap(uint64_t vm_handle, uint64_t bo_handle, uint64_t va, uint64_t size)
{
    struct amdgpu_device *adev = NULL;
    struct nmx_accel_vm *vm;
    struct nmx_accel_bo_record *bo;
    struct nmx_accel_vm_bo *vm_bo;
    struct nmx_accel_vm_mapping *mapping;
    struct nmx_accel_vm_mapping **link;
    struct drm_exec exec;
    int r = nmx_accel_bridge_vm_gate(&adev);
    if (r)
        return r;
    if (vm_handle == 0 || bo_handle == 0)
        return -EINVAL;
    r = nmx_accel_bridge_vm_check_range(adev, va, 0, size);
    if (r)
        return r;

    mutex_lock(&g_vm_lock);
    vm = nmx_accel_vm_find_locked(vm_handle);
    if (vm == NULL || vm->adev != adev) {
        mutex_unlock(&g_vm_lock);
        return -EINVAL;
    }
    mutex_lock(&g_bo_lock);
    bo = nmx_accel_bo_find_locked(bo_handle);
    vm_bo = bo != NULL ? nmx_accel_vm_bo_find_locked(vm, bo) : NULL;
    mapping = vm_bo != NULL ? nmx_accel_vm_mapping_find_locked(vm_bo, va, size) : NULL;
    if (bo == NULL || bo->adev != adev || vm_bo == NULL || mapping == NULL) {
        mutex_unlock(&g_bo_lock);
        mutex_unlock(&g_vm_lock);
        return -ENOENT;
    }
    r = nmx_accel_bridge_vm_lock(vm, bo, &exec);
    if (r) {
        drm_exec_fini(&exec);
        goto unmap_out;
    }
    r = amdgpu_vm_bo_unmap(adev, vm_bo->bo_va, va);
    if (r)
        goto unmap_unlock;
    r = nmx_accel_vm_update(vm, vm_bo, false);
    if (r)
        goto unmap_unlock;
    link = &vm_bo->mappings;
    while (*link != mapping)
        link = &(*link)->next;
    *link = mapping->next;
    kfree(mapping);
unmap_unlock:
    drm_exec_fini(&exec);
unmap_out:
    mutex_unlock(&g_bo_lock);
    mutex_unlock(&g_vm_lock);
    return r;
}

/*
 * Client submit (Phase D): the only entry for client work, distinct from the NULL-job selftest submit above. Gates and
 * shape checks run before any amdgpu call: device gates, VM handle, ring bounds, dword-aligned IB with a non-zero
 * length whose end does not overflow. A shape-valid IB is refused: no task VM, bo_va mapping, scheduler entity, or
 * job lifetime is verified, so the IB cannot be proven mapped in that VM and no job or fence is ever produced.
 * shortcut: no drm_sched entity or job lifetime exists yet, so every valid request returns -ENOTSUP; upgrade with a
 * bridge-owned entity and the IB containment check against the bo_va mapping records (accel-vm-gate report). */
int nmx_accel_bridge_client_submit(uint64_t vm, uint32_t ring, uint64_t ib_addr, uint32_t ib_dw, uint64_t *fence_out)
{
    if (fence_out)
        *fence_out = 0;
    struct amdgpu_device *adev = NULL;
    int r = nmx_accel_bridge_vm_gate(&adev);
    if (r)
        return r;
    if (vm == 0 || ring >= adev->gfx.num_gfx_rings)
        return -EINVAL;
    if (ib_addr == 0 || ib_dw == 0 || (ib_addr & 3) != 0 || ib_addr > ~(uint64_t)0 - (uint64_t)ib_dw * 4)
        return -EINVAL;
    return -ENOTSUP;
}

/*
 * Boot-arg selftest (raphaeli-accel-test=1), called once after the driver attached (nmx_kext.cpp,
 * Raphaeli::attachNow): two PACKET3 NOPs in a GTT buffer go through the accel hooks onto gfx ring 0,
 * the fence is waited on and the result logged. Failed waits retain the IB rather than freeing memory
 * the GPU may still read; without the boot argument this does nothing.
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
    bool ib_in_flight = false;
    kern_return_t kr = nmx_xnu_accel_ring_submit(0, gpu_addr, 2, &fence);
    if (kr != KERN_SUCCESS) {
        printf("Raphaeli accel selftest: submit refused (0x%x)\n", kr);
        r = -1;
    } else {
        kr = nmx_xnu_accel_fence_wait(fence, 5000);
        ib_in_flight = kr != KERN_SUCCESS;
        printf("Raphaeli accel selftest: gfx ring 0 NOP IB submitted, fence %s (0x%x)\n",
               kr == KERN_SUCCESS ? "signaled: PASS" : "NOT signaled: FAIL", kr);
        r = kr == KERN_SUCCESS ? 0 : -1;
    }
    /* the memory plane: one pinned VRAM BO through the bridge the vendor vid memory uses (v2) */
    {
        uint64_t bo = 0, vaddr = 0;
        void *kva = NULL;
        int m = nmx_accel_bridge_alloc(4096, 4096, AMDGPU_GEM_DOMAIN_VRAM, &bo, &vaddr, &kva);
        if (m == 0 && bo != 0 && vaddr != 0) {
            uint64_t off = nmx_accel_bridge_dmap(bo);
            nmx_accel_bridge_free(bo, vaddr, kva);
            printf("Raphaeli accel selftest: VRAM alloc 4096 B, device address 0x%llx: %s\n",
                   (unsigned long long)off, off != 0 ? "PASS" : "FAIL (no device address)");
            if (off == 0)
                r = -1;
        } else {
            printf("Raphaeli accel selftest: VRAM alloc refused (%d): FAIL\n", m);
            r = -1;
        }
    }
    if (!ib_in_flight)
        amdgpu_bo_free_kernel(&bo, &gpu_addr, &cpu);
    else
        /* shortcut: retain the selftest's 4 KiB IB after a failed wait, release after reset once reset cleanup exists. */
        printf("Raphaeli accel selftest: retaining 4096 B IB until reboot (completion unconfirmed)\n");
    return r;
}
