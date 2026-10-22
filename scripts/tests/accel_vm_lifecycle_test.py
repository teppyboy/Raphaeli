"""Host contract for the bridge-owned task VM lifecycle.

nmx_accel_bridge_vm_create calls the pinned amdgpu_vm_init with the KMS open path's XCP value, and destroy or
nmx_accel_bridge_vm_release_all calls amdgpu_vm_fini. This test compiles the real bridge bodies against amdgpu stubs
that count calls, and proves: device gates refuse before any amdgpu call; the XCP value matches the open path; an
init failure frees its record; destroy releases exactly the live record; an unknown or repeated handle is refused
without touching amdgpu; and release-all frees every live record. Map/unmap use the real bo_va path (see
accel_vm_mapping_test.py).
"""
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "Raphaeli/Override/src/nmx_accel_bridge.c").read_text()
AMDGPU = ROOT / "kpi/drm-kmod/drivers/gpu/drm/amd/amdgpu"
KMS = (AMDGPU / "amdgpu_kms.c").read_text()
VM_SOURCE = (AMDGPU / "amdgpu_vm.c").read_text()
XCP = (AMDGPU / "amdgpu_xcp.c").read_text()
PORT_C = (ROOT / "Raphaeli/Compat/src/nmx_port.c").read_text()
PORT_HEADERS = [
    (ROOT / "Raphaeli/Compat/include/nmx_port.h").read_text(),
    (ROOT / "Raphaeli/Compat/include/nmxxnu/nmx_port.h").read_text(),
]


def source_function(source, signature):
    start = source.find(signature)
    if start < 0:
        raise AssertionError("missing source function " + signature)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


# Pinned amdgpu lifecycle: the open path passes fpriv->xcp_id, and fini is the matching teardown.
open_kms = source_function(KMS, "int amdgpu_driver_open_kms(")
assert "r = amdgpu_vm_init(adev, &fpriv->vm, fpriv->xcp_id);" in open_kms
xcp_open = source_function(XCP, "int amdgpu_xcp_open_device(")
assert "if (!adev->xcp_mgr)" in xcp_open and "fpriv->xcp_id = AMDGPU_XCP_NO_PARTITION;" in xcp_open
vm_fini = source_function(VM_SOURCE, "void amdgpu_vm_fini(")
assert "amdgpu_vm_set_pasid(adev, vm, 0);" in vm_fini

# Port wiring: nmx_port_detach releases task VMs before the device is removed.
detach = source_function(PORT_C, "void nmx_port_detach(void *dev)")
assert detach.index("nmx_accel_bridge_vm_release_all();") < detach.index("nmx_bus_remove_device(dev);")
for header in PORT_HEADERS:
    assert "void nmx_accel_bridge_vm_release_all(void);" in header

# Static contract: no file-scope amdgpu_vm; map/unmap keep their own gates.
assert not re.search(r"^(?:static\s+)?struct\s+amdgpu_vm\b", SOURCE, re.M), "no file-scope (global) amdgpu_vm"
assert "raphaeli-accel-client-test" not in SOURCE, "client test flag must stay absent"

# The registry block (record type, lock, list head, and every function that touches them) is one contiguous span.
REGISTRY = SOURCE[SOURCE.index("struct nmx_accel_vm {"):SOURCE.index("/* device gates shared by map/unmap")]
assert "static DEFINE_MUTEX(g_vm_lock);" in SOURCE and "static struct nmx_accel_vm *g_vms;" in REGISTRY
# The release path and create path must reach amdgpu only through these pinned calls.
create = source_function(SOURCE, "int nmx_accel_bridge_vm_create(")
assert create.count("amdgpu_vm_init(") == 1 and "amdgpu_vm_fini(" not in create
assert "xcp_mgr != NULL ? AMDGPU_XCP_NO_PARTITION : 0" in create
assert create.index("amdgpu_vm_init(") < create.index("vm->adev = adev;")
assert "kfree(vm);" in create.split("amdgpu_vm_init(")[1].split("}")[0]
fini = source_function(SOURCE, "static int nmx_accel_vm_fini(")
assert "drm_exec_fini(&exec);" in fini and "if (r)\n        return -EBUSY;" in fini
release_all = source_function(SOURCE, "void nmx_accel_bridge_vm_release_all(")
assert "attempt < 3" in release_all and "g_vms = NULL" not in release_all

# The lifecycle harness compiles the real VM-registry span (locks, BO record, free, VM create/destroy/release-all,
# gates, map, unmap) against stubs; the mapping contract (accel_vm_mapping_test.py) checks the map/unmap bodies in it.
def span(begin, end):
    return SOURCE[SOURCE.index(begin):SOURCE.index(end)]


HARNESS = r'''
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef uint64_t u64;
#define AMDGPU_XCP_NO_PARTITION (~0)
#define AMDGPU_GPU_PAGE_SIZE 4096
#define AMDGPU_GPU_PAGE_SHIFT 12
#define AMDGPU_GPU_PAGE_MASK (AMDGPU_GPU_PAGE_SIZE - 1)
#define AMDGPU_GMC_HOLE_START 0x0000800000000000ULL
#define AMDGPU_GMC_HOLE_END 0xffff800000000000ULL
#define AMDGPU_VA_RESERVED_BOTTOM (1ULL << 16)
#define AMDGPU_VA_RESERVED_TRAP_SIZE (2ULL << 12)
#define AMDGPU_VA_RESERVED_SEQ64_SIZE (2ULL << 20)
#define AMDGPU_VA_RESERVED_CSA_SIZE (2ULL << 20)
#define AMDGPU_VA_RESERVED_TOP (AMDGPU_VA_RESERVED_TRAP_SIZE + AMDGPU_VA_RESERVED_SEQ64_SIZE + AMDGPU_VA_RESERVED_CSA_SIZE)
#define DEFINE_MUTEX(name) int name
#define mutex_lock(m) (void)(m)
#define mutex_unlock(m) (void)(m)
#define GFP_KERNEL 0
#define DRM_EXEC_INTERRUPTIBLE_WAIT 1
#define DRM_EXEC_IGNORE_DUPLICATES 2
#define kzalloc(size, flags) calloc(1, (size))
#define kfree(p) free(p)
#define drm_exec_until_all_locked(exec) for (int __once = 1; __once; __once = 0)
#define drm_exec_retry_on_contention(exec) ((void)0)

struct drm_exec { int locks; };
struct drm_gpu_scheduler { int unused; };
struct amdgpu_sched { struct drm_gpu_scheduler **sched; unsigned num_scheds; };
struct drm_sched_entity { int unused; };
struct dma_fence { int unused; };
struct amdgpu_ib { u64 gpu_addr; unsigned length_dw; };
struct amdgpu_job { unsigned num_ibs; struct amdgpu_ib ibs[1]; };
struct amdgpu_xcp_mgr { int unused; };
struct amdgpu_vm_manager { u64 max_pfn; };
struct amdgpu_device {
    bool accel_working;
    bool in_suspend;
    bool shutdown;
    struct amdgpu_vm_manager vm_manager;
    struct amdgpu_sched gpu_sched[1][2];
    struct amdgpu_xcp_mgr *xcp_mgr;
};
struct amdgpu_vm { int pasid; };
struct ttm_bo_stub { int unused; };
struct amdgpu_bo { u64 size; int kmapped; struct { struct ttm_bo_stub base; } tbo; };
struct amdgpu_bo_va { struct amdgpu_bo *bo; int maps; };
static struct amdgpu_device device = { .accel_working = true, .vm_manager = { 1ULL << 20 } };
static void *g_iopci = &device;
struct amdgpu_device *adev_of(void *iopci) { return iopci == &device ? &device : NULL; }

int vm_init_calls, vm_fini_calls, vm_init_fail;
int vm_lock_fail;
int32_t last_xcp_id;
int amdgpu_vm_init(struct amdgpu_device *a, struct amdgpu_vm *vm, int32_t xcp_id) {
    (void)a; (void)vm; ++vm_init_calls; last_xcp_id = xcp_id; return vm_init_fail;
}
void amdgpu_vm_fini(struct amdgpu_device *a, struct amdgpu_vm *vm) { (void)a; (void)vm; ++vm_fini_calls; }
int drm_sched_entity_init(struct drm_sched_entity *entity, int priority,
                           struct drm_gpu_scheduler **sched, unsigned num, void *guilty) {
    (void)entity; (void)priority; (void)sched; (void)num; (void)guilty; return 0;
}
int amdgpu_job_alloc(struct amdgpu_device *a, struct amdgpu_vm *vm, struct drm_sched_entity *entity,
                     void *owner, unsigned num_ibs, struct amdgpu_job **job) {
    (void)a; (void)vm; (void)entity; (void)owner; (void)num_ibs; (void)job; return -ENOMEM;
}
struct dma_fence *amdgpu_job_submit(struct amdgpu_job *job) { (void)job; return NULL; }
void amdgpu_job_free(struct amdgpu_job *job) { (void)job; }
struct amdgpu_bo_va *amdgpu_vm_bo_add(struct amdgpu_device *a, struct amdgpu_vm *vm, struct amdgpu_bo *bo) {
    (void)a; (void)vm; struct amdgpu_bo_va *v = calloc(1, sizeof(*v)); v->bo = bo; return v;
}
int amdgpu_vm_bo_map(struct amdgpu_device *a, struct amdgpu_bo_va *v, u64 addr, u64 offset, u64 size, u64 flags) {
    (void)a; (void)v; (void)addr; (void)offset; (void)size; (void)flags; return 0;
}
int amdgpu_vm_bo_unmap(struct amdgpu_device *a, struct amdgpu_bo_va *v, u64 addr) { (void)a; (void)v; (void)addr; return 0; }
void amdgpu_vm_bo_del(struct amdgpu_device *a, struct amdgpu_bo_va *v) { (void)a; free(v); }
int amdgpu_vm_bo_update(struct amdgpu_device *a, struct amdgpu_bo_va *v, bool clear) { (void)a; (void)v; (void)clear; return 0; }
bool amdgpu_vm_ready(struct amdgpu_vm *vm) { (void)vm; return true; }
int amdgpu_vm_clear_freed(struct amdgpu_device *a, struct amdgpu_vm *vm, void *f) { (void)a; (void)vm; (void)f; return 0; }
int amdgpu_vm_update_pdes(struct amdgpu_device *a, struct amdgpu_vm *vm, bool immediate) { (void)a; (void)vm; (void)immediate; return 0; }
int amdgpu_vm_lock_pd(struct amdgpu_vm *vm, struct drm_exec *exec, unsigned int n) { (void)vm; (void)n; exec->locks++; return vm_lock_fail ? -EBUSY : 0; }
int drm_exec_lock_obj(struct drm_exec *exec, void *obj) { (void)obj; exec->locks++; return 0; }
void drm_exec_init(struct drm_exec *exec, unsigned flags, unsigned n) { (void)flags; (void)n; exec->locks = 0; }
void drm_exec_fini(struct drm_exec *exec) { (void)exec; }
int amdgpu_bo_reserve(struct amdgpu_bo *bo, bool no_intr) { (void)bo; (void)no_intr; return 0; }
void amdgpu_bo_kunmap(struct amdgpu_bo *bo) { (void)bo; }
void amdgpu_bo_unpin(struct amdgpu_bo *bo) { (void)bo; }
void amdgpu_bo_unreserve(struct amdgpu_bo *bo) { (void)bo; }
void amdgpu_bo_unref(struct amdgpu_bo **bo) { (void)bo; }
u64 amdgpu_bo_gpu_offset(struct amdgpu_bo *bo) { (void)bo; return 0; }
'''
HARNESS += span("/* VM and BO registries are bridge ownership boundaries", "kern_return_t nmx_xnu_accel_ring_submit(")
HARNESS += span("uint64_t nmx_accel_bridge_dmap(uint64_t bo)", "int nmx_accel_bridge_fence_wait(")
HARNESS += span("struct nmx_accel_vm_bo;", "int nmx_accel_bridge_client_submit(")
HARNESS += r'''
#define VM_ASSERT_NO_AMDGPU(v, f) assert(vm_init_calls == (v) && vm_fini_calls == (f))
int main(void) {
    uint64_t vm = 0xdead;
    /* device gates refuse before any amdgpu call */
    g_iopci = NULL;
    assert(nmx_accel_bridge_vm_create(&vm) == -ENODEV && vm == 0);
    g_iopci = &device;
    device.accel_working = false;
    assert(nmx_accel_bridge_vm_create(&vm) == -ENODEV && vm == 0);
    device.accel_working = true;
    device.in_suspend = true;
    assert(nmx_accel_bridge_vm_create(&vm) == -EBUSY && vm == 0);
    device.in_suspend = false;
    device.shutdown = true;
    assert(nmx_accel_bridge_vm_create(&vm) == -EBUSY && vm == 0);
    device.shutdown = false;
    assert(nmx_accel_bridge_vm_create(NULL) == -EINVAL);
    VM_ASSERT_NO_AMDGPU(0, 0);

    /* no partition manager: the open path leaves xcp_id at 0 */
    assert(nmx_accel_bridge_vm_create(&vm) == 0 && vm != 0);
    assert(last_xcp_id == 0 && vm_init_calls == 1);
    uint64_t first = vm;
    /* with a partition manager the open path's NO_PARTITION value is used */
    struct amdgpu_xcp_mgr mgr;
    device.xcp_mgr = &mgr;
    uint64_t second = 0;
    assert(nmx_accel_bridge_vm_create(&second) == 0 && second != 0 && second != first);
    assert(last_xcp_id == AMDGPU_XCP_NO_PARTITION);
    device.xcp_mgr = NULL;

    /* destroy releases the exact live record; a repeated or unknown handle is refused without amdgpu */
    assert(nmx_accel_bridge_vm_destroy(second) == 0);
    VM_ASSERT_NO_AMDGPU(2, 1);
    assert(nmx_accel_bridge_vm_destroy(second) == -EINVAL);
    assert(nmx_accel_bridge_vm_destroy(0) == -EINVAL);
    assert(nmx_accel_bridge_vm_destroy(0xbad) == -EINVAL);
    VM_ASSERT_NO_AMDGPU(2, 1);

    /* a failed amdgpu_vm_init issues no handle and frees its record */
    vm_init_fail = -ENOMEM;
    vm = 0xdead;
    assert(nmx_accel_bridge_vm_create(&vm) == -ENOMEM && vm == 0);
    vm_init_fail = 0;
    VM_ASSERT_NO_AMDGPU(3, 1);

    /* contention is a failed teardown: fini is called, but the live VM remains registered */
    vm_lock_fail = 1;
    assert(nmx_accel_bridge_vm_destroy(first) == -EBUSY);
    VM_ASSERT_NO_AMDGPU(3, 1);
    nmx_accel_bridge_vm_release_all();
    VM_ASSERT_NO_AMDGPU(3, 1);
    vm_lock_fail = 0;
    /* release-all retries and frees the retained record, then nothing */
    nmx_accel_bridge_vm_release_all();
    VM_ASSERT_NO_AMDGPU(3, 2);
    assert(nmx_accel_bridge_vm_destroy(first) == -EINVAL);
    nmx_accel_bridge_vm_release_all();
    VM_ASSERT_NO_AMDGPU(3, 2);
    puts("PASS: bridge-owned task VM lifecycle: create via amdgpu_vm_init, destroy, release-all, refusals");
    return 0;
}
'''

with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    source = path / "vm_lifecycle.c"
    source.write_text(HARNESS)
    subprocess.run(["clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function", "-Wno-unused-variable", str(source),
                    "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
