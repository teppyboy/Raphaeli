"""Host contract for BO/VA mapping records in the bridge (accel-map lane).

nmx_accel_bridge_vm_map and nmx_accel_bridge_vm_unmap record each BO range in a bridge-owned bo_va table under
drm_exec PD and BO locks, with the pinned amdgpu_vm_bo_add / amdgpu_vm_bo_map / amdgpu_vm_bo_unmap / amdgpu_vm_bo_del
calls. This test compiles the real registry, map, unmap, free, destroy, and release-all bodies against stubs that
record every amdgpu call and every lock, and proves: device gates precede every check; handle, range, and BO-size
validation refuse before any amdgpu call; a successful map records exactly one mapping; a failed map leaves no record;
unmap only removes a recorded range; a mapped BO cannot be freed; teardown releases every bo_va and the PD exactly
once; and drm_exec is finalised on every lock-failure path.
"""
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "Raphaeli/Override/src/nmx_accel_bridge.c").read_text()
PORT_HEADERS = [
    (ROOT / "Raphaeli/Compat/include/nmx_port.h").read_text(),
    (ROOT / "Raphaeli/Compat/include/nmxxnu/nmx_port.h").read_text(),
]
AMDGPU = ROOT / "kpi/drm-kmod/drivers/gpu/drm/amd/amdgpu"
PINNED_VM_H = (AMDGPU / "amdgpu_vm.h").read_text()
PINNED_GMC_H = (AMDGPU / "amdgpu_gmc.h").read_text()
PINNED_GART_H = (AMDGPU / "amdgpu_gart.h").read_text()


def function(name, return_type="int"):
    start = SOURCE.find(return_type + " " + name + "(")
    if start < 0:
        raise AssertionError("missing bridge function " + name)
    opening = SOURCE.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (SOURCE[end] == "{") - (SOURCE[end] == "}")
        end += 1
    return SOURCE[start:end]


FLAT_SOURCE = re.sub(r"\s+", " ", SOURCE)
MAP_SIGNATURE = ("int nmx_accel_bridge_vm_map(uint64_t vm_handle, uint64_t bo_handle, uint64_t va, "
                 "uint64_t offset, uint64_t size, uint64_t flags) {")
UNMAP_SIGNATURE = "int nmx_accel_bridge_vm_unmap(uint64_t vm_handle, uint64_t bo_handle, uint64_t va, uint64_t size) {"
for header in PORT_HEADERS:
    assert "int nmx_accel_bridge_vm_map(uint64_t vm" in header and "uint64_t flags);" in header
    assert "int nmx_accel_bridge_vm_unmap(uint64_t vm" in header
assert MAP_SIGNATURE in FLAT_SOURCE
assert UNMAP_SIGNATURE in FLAT_SOURCE

map_body = function("nmx_accel_bridge_vm_map")
unmap_body = function("nmx_accel_bridge_vm_unmap")
gate = function("nmx_accel_bridge_vm_gate", "static int")
check_range = function("nmx_accel_bridge_vm_check_range", "static int")
free_body = function("nmx_accel_bridge_free")
destroy_body = function("nmx_accel_bridge_vm_destroy")
release_body = function("nmx_accel_bridge_vm_release_all", "void")
fini_body = function("nmx_accel_vm_fini", "static int")

# Device gates and range checks run before any registry or amdgpu access.
assert map_body.index("nmx_accel_bridge_vm_gate(") < map_body.index("nmx_accel_bridge_vm_check_range(")
assert map_body.index("nmx_accel_bridge_vm_check_range(") < map_body.index("mutex_lock(&g_vm_lock)")
assert unmap_body.index("nmx_accel_bridge_vm_gate(") < unmap_body.index("nmx_accel_bridge_vm_check_range(")
assert unmap_body.index("nmx_accel_bridge_vm_check_range(") < unmap_body.index("mutex_lock(&g_vm_lock)")
assert "adev->in_suspend || adev->shutdown" in gate and "-ENODEV" in gate and "-EBUSY" in gate

# The mapping path uses exactly the pinned bo_va calls, in the pinned order.
for call in ("amdgpu_vm_bo_add(", "amdgpu_vm_bo_map(", "amdgpu_vm_bo_unmap(", "amdgpu_vm_bo_del("):
    assert call in SOURCE, call
for name in ("amdgpu_vm_bo_add", "amdgpu_vm_bo_map", "amdgpu_vm_bo_unmap", "amdgpu_vm_bo_del"):
    assert re.search(r"\b" + name + r"\s*\(", PINNED_VM_H), name
assert map_body.index("amdgpu_vm_bo_add(") < map_body.index("amdgpu_vm_bo_map(")
assert unmap_body.index("amdgpu_vm_bo_unmap(") < unmap_body.index("kfree(mapping)")

# The PD lock is taken through the pinned helper, and every lock path finalises its drm_exec.
assert "amdgpu_vm_lock_pd(" in SOURCE and "drm_exec_init(" in SOURCE
assert "drm_exec_fini(&exec);" in map_body and "drm_exec_fini(&exec);" in unmap_body
assert "drm_exec_fini(&exec);" in fini_body

# Teardown order: every bo_va is removed before its VM is finalised, under the BO and VM registry locks.
assert destroy_body.index("mutex_lock(&g_vm_lock)") < destroy_body.index("mutex_lock(&g_bo_lock)")
assert release_body.index("mutex_lock(&g_vm_lock)") < release_body.index("mutex_lock(&g_bo_lock)")
assert fini_body.index("amdgpu_vm_bo_del(") < fini_body.index("amdgpu_vm_fini(")

# free refuses a mapped BO before any reserve or teardown.
assert free_body.index("nmx_accel_bridge_bo_is_mapped(") < free_body.index("amdgpu_bo_reserve(")
assert free_body.index("amdgpu_bo_reserve(") < free_body.index("amdgpu_bo_kunmap(")
order = [free_body.index(token) for token in ("amdgpu_bo_kunmap", "amdgpu_bo_unpin",
                                              "amdgpu_bo_unreserve", "amdgpu_bo_unref")]
assert order == sorted(order)

# The pinned constants come from the pinned headers, not a guessed range.
for header, name in (
    (PINNED_GART_H, "AMDGPU_GPU_PAGE_SIZE"),
    (PINNED_GART_H, "AMDGPU_GPU_PAGE_SHIFT"),
    (PINNED_GMC_H, "AMDGPU_GMC_HOLE_START"),
    (PINNED_GMC_H, "AMDGPU_GMC_HOLE_END"),
    (PINNED_VM_H, "AMDGPU_VA_RESERVED_BOTTOM"),
    (PINNED_VM_H, "AMDGPU_VA_RESERVED_TOP"),
):
    assert re.search(r"#define\s+" + name + r"\b", header), name

# No file-scope amdgpu_vm or amdgpu_bo_va: records live only in the registries.
assert not re.search(r"^(?:static\s+)?struct\s+amdgpu_(?:vm|bo_va)\b", SOURCE, re.M)

HARNESS = r'''
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef uint64_t u64;
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
#define mutex_lock(m) lock_take(m)
#define mutex_unlock(m) lock_drop(m)
#define GFP_KERNEL 0
#define DRM_EXEC_INTERRUPTIBLE_WAIT 1
#define DRM_EXEC_IGNORE_DUPLICATES 2
#define kzalloc(size, flags) calloc(1, (size))
#define kfree(p) free(p)

struct drm_exec { int locks; };
struct drm_gpu_scheduler { int unused; };
struct amdgpu_sched { struct drm_gpu_scheduler **sched; unsigned num_scheds; };
struct drm_sched_entity { int unused; };
struct dma_fence { int unused; };
struct amdgpu_ib { u64 gpu_addr; unsigned length_dw; };
struct amdgpu_job { unsigned num_ibs; struct amdgpu_ib ibs[1]; };
struct amdgpu_vm_manager { u64 max_pfn; };
struct amdgpu_xcp_mgr { int unused; };
struct amdgpu_device {
    bool accel_working;
    bool in_suspend;
    bool shutdown;
    struct amdgpu_vm_manager vm_manager;
    struct amdgpu_xcp_mgr *xcp_mgr;
    struct amdgpu_sched gpu_sched[1][2];
};
#define AMDGPU_XCP_NO_PARTITION (~0)
struct amdgpu_vm { int init; };
struct drm_gem_obj_stub { int unused; };
struct ttm_bo_stub { struct drm_gem_obj_stub base; };
struct amdgpu_bo { u64 size; int kmapped; struct ttm_bo_stub tbo; };
struct amdgpu_bo_va { struct amdgpu_bo *bo; int maps; };

static struct amdgpu_device device = { .accel_working = true, .vm_manager = { 1ULL << 20 } };
static void *g_iopci = &device;
struct amdgpu_device *adev_of(void *iopci) { return iopci == &device ? &device : NULL; }

/* every pinned call is recorded so a test can assert the exact sequence and count */
static int lock_depth;
static int lock_takes, lock_drops;
static void lock_take(int *m) { (void)m; lock_depth++; lock_takes++; }
static void lock_drop(int *m) { (void)m; lock_depth--; lock_drops++; }
static int bo_add_calls, bo_map_calls, bo_unmap_calls, bo_del_calls, bo_update_calls;
static int vm_init_calls, vm_fini_calls, pd_lock_calls, exec_init_calls, exec_fini_calls;
static int reserve_calls, kunmap_calls, unpin_calls, unref_calls;
static int fail_pd_lock, fail_bo_map, fail_update, fail_unmap, fail_reserve;
static int update_calls;
static void *last_bo_va;

struct amdgpu_bo_va *amdgpu_vm_bo_add(struct amdgpu_device *a, struct amdgpu_vm *vm, struct amdgpu_bo *bo) {
    (void)a; (void)vm; ++bo_add_calls;
    struct amdgpu_bo_va *v = calloc(1, sizeof(*v));
    v->bo = bo;
    last_bo_va = v;
    return v;
}
int amdgpu_vm_bo_map(struct amdgpu_device *a, struct amdgpu_bo_va *v, u64 addr, u64 offset, u64 size, u64 flags) {
    (void)a; (void)addr; (void)offset; (void)size; (void)flags;
    ++bo_map_calls;
    if (fail_bo_map) return fail_bo_map;
    v->maps++;
    return 0;
}
int amdgpu_vm_bo_unmap(struct amdgpu_device *a, struct amdgpu_bo_va *v, u64 addr) {
    (void)a; (void)addr; ++bo_unmap_calls;
    if (fail_unmap) return fail_unmap;
    v->maps--;
    return 0;
}
void amdgpu_vm_bo_del(struct amdgpu_device *a, struct amdgpu_bo_va *v) { (void)a; ++bo_del_calls; free(v); }
int amdgpu_vm_bo_update(struct amdgpu_device *a, struct amdgpu_bo_va *v, bool clear) { (void)a; (void)v; (void)clear; ++bo_update_calls; return 0; }
bool amdgpu_vm_ready(struct amdgpu_vm *vm) { (void)vm; return true; }
int amdgpu_vm_clear_freed(struct amdgpu_device *a, struct amdgpu_vm *vm, void *fence) { (void)a; (void)vm; (void)fence; return 0; }
int amdgpu_vm_update_pdes(struct amdgpu_device *a, struct amdgpu_vm *vm, bool immediate) {
    (void)a; (void)vm; (void)immediate;
    ++update_calls;
    return fail_update;
}
int amdgpu_vm_lock_pd(struct amdgpu_vm *vm, struct drm_exec *exec, unsigned int n) {
    (void)vm; (void)n; ++pd_lock_calls;
    exec->locks++;
    return fail_pd_lock;
}
int drm_exec_lock_obj(struct drm_exec *exec, void *obj) { (void)obj; exec->locks++; return 0; }
void drm_exec_init(struct drm_exec *exec, unsigned flags, unsigned n) { (void)flags; (void)n; exec->locks = 0; ++exec_init_calls; }
void drm_exec_fini(struct drm_exec *exec) { (void)exec; ++exec_fini_calls; }
/* a single pass: the stub never reports contention, so the loop body runs once */
int drm_exec_until_all_locked_once;
#define drm_exec_until_all_locked(exec) for (int __once = 1; __once; __once = 0)
#define drm_exec_retry_on_contention(exec) ((void)0)

int amdgpu_vm_init(struct amdgpu_device *a, struct amdgpu_vm *vm, int32_t xcp_id) { (void)a; (void)xcp_id; ++vm_init_calls; vm->init = 1; return 0; }
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
int amdgpu_bo_reserve(struct amdgpu_bo *bo, bool no_intr) { (void)bo; (void)no_intr; ++reserve_calls; return fail_reserve; }
void amdgpu_bo_kunmap(struct amdgpu_bo *bo) { (void)bo; ++kunmap_calls; }
void amdgpu_bo_unpin(struct amdgpu_bo *bo) { (void)bo; ++unpin_calls; }
void amdgpu_bo_unreserve(struct amdgpu_bo *bo) { (void)bo; }
void amdgpu_bo_unref(struct amdgpu_bo **bo) { (void)bo; ++unref_calls; }
static inline unsigned long amdgpu_bo_size(struct amdgpu_bo *bo) { return bo->size; }
u64 amdgpu_bo_gpu_offset(struct amdgpu_bo *bo) { (void)bo; return 0; }
'''
# The real ownership code, in source order and without the FreeBSD device walk or the IB/selftest paths: the locks and
# BO record, dmap and free, then the VM registry through vm_unmap. Every helper these bodies use is inside these spans.
def span(begin, end):
    return SOURCE[SOURCE.index(begin):SOURCE.index(end)]


HARNESS += span("/* VM and BO registries are bridge ownership boundaries", "kern_return_t nmx_xnu_accel_ring_submit(")
HARNESS += span("uint64_t nmx_accel_bridge_dmap(uint64_t bo)", "int nmx_accel_bridge_fence_wait(")
HARNESS += span("struct nmx_accel_vm_bo;", "int nmx_accel_bridge_client_submit(")
HARNESS += r'''
static void reset_counts(void) {
    lock_depth = lock_takes = lock_drops = 0;
    bo_add_calls = bo_map_calls = bo_unmap_calls = bo_del_calls = bo_update_calls = 0;
    vm_init_calls = vm_fini_calls = pd_lock_calls = exec_init_calls = exec_fini_calls = 0;
    reserve_calls = kunmap_calls = unpin_calls = unref_calls = update_calls = 0;
    fail_pd_lock = fail_bo_map = fail_update = fail_unmap = fail_reserve = 0;
}
static void assert_balanced(void) {
    assert(lock_depth == 0);
    assert(exec_init_calls == exec_fini_calls);
}
static u64 new_vm(void) {
    u64 h = 0;
    device.accel_working = true;
    assert(nmx_accel_bridge_vm_create(&h) == 0 && h != 0);
    return h;
}
int main(void) {
    struct amdgpu_bo bo = { 8192, 1, { { 0 } } };
    u64 vm = new_vm();
    u64 bo_h = (u64)(uintptr_t)&bo;
    /* register the BO as the allocator would */
    struct nmx_accel_bo_record *rec = calloc(1, sizeof(*rec));
    rec->bo = &bo; rec->adev = &device; rec->size = 8192; rec->next = g_bos; g_bos = rec;
    reset_counts();

    /* a successful map records exactly one range and touches amdgpu exactly once per step */
    assert(nmx_accel_bridge_vm_map(vm, bo_h, 0x100000, 0, 4096, 0) == 0);
    assert(bo_add_calls == 1 && bo_map_calls == 1 && update_calls == 1);
    assert_balanced();

    /* a repeated map of a different range on the same BO reuses the bo_va */
    assert(nmx_accel_bridge_vm_map(vm, bo_h, 0x101000, 4096, 4096, 0) == 0);
    assert(bo_add_calls == 1 && bo_map_calls == 2);
    assert_balanced();

    /* range refusals happen before any amdgpu call or lock */
    reset_counts();
    assert(nmx_accel_bridge_vm_map(vm, bo_h, 0x100001, 0, 4096, 0) == -EINVAL);
    assert(nmx_accel_bridge_vm_map(vm, bo_h, 0x100000, 4096, 8192, 0) == -EINVAL);
    assert(nmx_accel_bridge_vm_map(vm, bo_h, 0, 0, 4096, 0) == -EINVAL);
    assert(bo_add_calls == 0 && bo_map_calls == 0 && exec_init_calls == 0);

    /* unknown VM or BO handle refuses without a lock or amdgpu call */
    assert(nmx_accel_bridge_vm_map(0, bo_h, 0x200000, 0, 4096, 0) == -EINVAL);
    assert(nmx_accel_bridge_vm_map(vm, 0, 0x200000, 0, 4096, 0) == -EINVAL);
    assert(nmx_accel_bridge_vm_map(vm, 0xbad, 0x200000, 0, 4096, 0) == -EINVAL);
    assert(nmx_accel_bridge_vm_map(0xbad, bo_h, 0x200000, 0, 4096, 0) == -EINVAL);
    assert(bo_add_calls == 0 && bo_map_calls == 0 && exec_init_calls == 0);

    /* offset + size beyond the BO refuses before amdgpu */
    assert(nmx_accel_bridge_vm_map(vm, bo_h, 0x200000, 8192, 4096, 0) == -EINVAL);
    assert(bo_map_calls == 0);

    /* a failed amdgpu_vm_bo_map leaves no record and drops the drm_exec */
    reset_counts();
    fail_bo_map = -ENOMEM;
    assert(nmx_accel_bridge_vm_map(vm, bo_h, 0x300000, 0, 4096, 0) == -ENOMEM);
    /* the bo_va already exists for this BO, so it is kept and no PDE update runs */
    assert(bo_add_calls == 0 && bo_del_calls == 0 && update_calls == 0);
    assert_balanced();
    fail_bo_map = 0;

    /* a failed first map of a fresh BO removes the bo_va it just added */
    struct amdgpu_bo fresh = { 4096, 1, { { 0 } } };
    struct nmx_accel_bo_record *fresh_rec = calloc(1, sizeof(*fresh_rec));
    fresh_rec->bo = &fresh; fresh_rec->adev = &device; fresh_rec->size = 4096; fresh_rec->next = g_bos; g_bos = fresh_rec;
    reset_counts();
    fail_bo_map = -ENOMEM;
    assert(nmx_accel_bridge_vm_map(vm, (u64)(uintptr_t)&fresh, 0x310000, 0, 4096, 0) == -ENOMEM);
    assert(bo_add_calls == 1 && bo_del_calls == 1 && update_calls == 0);
    assert_balanced();
    fail_bo_map = 0;

    /* a failed PD lock refuses with no record and finalises drm_exec */
    reset_counts();
    fail_pd_lock = -EDEADLK;
    assert(nmx_accel_bridge_vm_map(vm, bo_h, 0x400000, 0, 4096, 0) == -EDEADLK);
    assert(bo_add_calls == 0 && bo_map_calls == 0);
    assert_balanced();
    fail_pd_lock = 0;

    /* a failed PDE update after a map rolls back the new mapping */
    reset_counts();
    fail_update = -EIO;
    assert(nmx_accel_bridge_vm_map(vm, bo_h, 0x500000, 0, 4096, 0) == -EIO);
    assert(bo_map_calls == 1 && bo_unmap_calls == 1);
    fail_update = 0;
    assert_balanced();

    /* the BO is mapped, so free refuses before reserve or teardown */
    reset_counts();
    assert(nmx_accel_bridge_free(bo_h, 8192, NULL) == -EBUSY);
    assert(reserve_calls == 0 && kunmap_calls == 0 && unref_calls == 0);
    assert_balanced();

    /* an unmap of a range that was never mapped refuses without amdgpu */
    reset_counts();
    assert(nmx_accel_bridge_vm_unmap(vm, bo_h, 0x999000, 4096) == -ENOENT);
    assert(bo_unmap_calls == 0 && update_calls == 0);
    assert_balanced();

    /* unmap a recorded range; the other range still keeps the BO mapped */
    reset_counts();
    assert(nmx_accel_bridge_vm_unmap(vm, bo_h, 0x101000, 4096) == 0);
    assert(bo_unmap_calls == 1 && update_calls == 1);
    assert_balanced();
    assert(nmx_accel_bridge_free(bo_h, 8192, NULL) == -EBUSY);

    /* a failed amdgpu_vm_bo_unmap keeps the record so the BO stays busy */
    reset_counts();
    fail_unmap = -EIO;
    assert(nmx_accel_bridge_vm_unmap(vm, bo_h, 0x100000, 4096) == -EIO);
    fail_unmap = 0;
    assert(nmx_accel_bridge_free(bo_h, 8192, NULL) == -EBUSY);
    assert_balanced();

    /* a failed PDE update after unmap keeps the mapping record too */
    reset_counts();
    fail_update = -EIO;
    assert(nmx_accel_bridge_vm_unmap(vm, bo_h, 0x100000, 4096) == -EIO);
    fail_update = 0;
    assert(nmx_accel_bridge_free(bo_h, 8192, NULL) == -EBUSY);
    assert_balanced();

    /* unmap the last range: the BO becomes unmapped and free now proceeds */
    reset_counts();
    assert(nmx_accel_bridge_vm_unmap(vm, bo_h, 0x100000, 4096) == 0);
    assert(nmx_accel_bridge_free(bo_h, 8192, NULL) == 0);
    assert(reserve_calls == 1 && kunmap_calls == 1 && unpin_calls == 1 && unref_calls == 1);
    assert_balanced();

    /* teardown: release-all finalises the VM, every bo_va and PD lock balanced */
    reset_counts();
    u64 vm2 = new_vm();
    u64 bo2_h = (u64)(uintptr_t)&bo;
    struct amdgpu_bo bo2 = { 8192, 1, { { 0 } } };
    bo2_h = (u64)(uintptr_t)&bo2;
    struct nmx_accel_bo_record *rec2 = calloc(1, sizeof(*rec2));
    rec2->bo = &bo2; rec2->adev = &device; rec2->size = 8192; rec2->next = g_bos; g_bos = rec2;
    assert(nmx_accel_bridge_vm_map(vm2, bo2_h, 0x600000, 0, 4096, 0) == 0);
    reset_counts();
    nmx_accel_bridge_vm_release_all();
    /* both live VMs are finalised: vm still holds the bo_va of bo, and vm2 holds the bo_va of bo2 */
    assert(bo_del_calls == 2 && vm_fini_calls == 2);
    assert_balanced();
    assert(nmx_accel_bridge_vm_destroy(vm2) == -EINVAL);
    puts("PASS: BO/VA mapping records: pinned bo_va calls, range/handle refusals, lock balance, rollback, BO free gating");
    return 0;
}
'''
HARNESS = HARNESS.replace("int nmx_accel_bridge_submit_unused;\n", "")

with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    source = path / "vm_mapping.c"
    source.write_text(HARNESS)
    subprocess.run(["clang", "-std=c2x", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function",
                    "-Wno-unused-variable", str(source), "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
