"""Focused host contract for fail-closed client submit until full VM job lifetime exists."""
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "Raphaeli/Override/src/nmx_accel_bridge.c").read_text()
PORT_HEADERS = [
    (ROOT / "Raphaeli/Compat/include/nmx_port.h").read_text(),
    (ROOT / "Raphaeli/Compat/include/nmxxnu/nmx_port.h").read_text(),
]
AMDGPU_JOB_H = (ROOT / "kpi/drm-kmod/drivers/gpu/drm/amd/amdgpu/amdgpu_job.h").read_text()

SIGNATURE = ("int nmx_accel_bridge_client_submit(uint64_t vm, uint32_t ring, uint64_t ib_addr, "
             "uint32_t ib_dw, uint64_t *fence_out);")


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


for header in PORT_HEADERS:
    assert SIGNATURE in header, "both shared port headers must declare the client submit"
client = function("nmx_accel_bridge_client_submit")
gate = function("nmx_accel_bridge_vm_gate", "static int")

# Until task-owned scheduler-entity teardown and VM/PASID state are wired,
# client submits must stay fail-closed and never call amdgpu.
assert "return -ENOTSUP;" in client
assert "amdgpu_job_alloc" not in client
assert "amdgpu_job_submit" not in client
assert "amdgpu_ib_schedule" not in client
assert client.index("nmx_accel_bridge_vm_gate(") < client.index("-ENOTSUP")
assert "ib_addr >= mapping->va" in client and "mapping->size - ib_size" in client

job_alloc = " ".join(AMDGPU_JOB_H[AMDGPU_JOB_H.index("int amdgpu_job_alloc("):AMDGPU_JOB_H.index("int amdgpu_job_alloc_with_ib(")].split())
assert job_alloc == ("int amdgpu_job_alloc(struct amdgpu_device *adev, struct amdgpu_vm *vm, "
                     "struct drm_sched_entity *entity, void *owner, unsigned int num_ibs, struct amdgpu_job **job);")

HARNESS = r'''
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
typedef uint64_t u64;
struct amdgpu_ib { uint64_t gpu_addr; uint32_t length_dw; };
struct amdgpu_vm { int unused; };
struct amdgpu_bo { int unused; };
struct drm_gpu_scheduler { int unused; };
struct amdgpu_sched { struct drm_gpu_scheduler **sched; unsigned num_scheds; };
struct drm_sched_entity { int unused; };
struct dma_fence { int value; };
struct amdgpu_job { unsigned num_ibs; struct amdgpu_ib ibs[1]; };
struct amdgpu_ring { int unused; };
struct amdgpu_gfx { unsigned num_gfx_rings; };
struct amdgpu_device {
    bool accel_working;
    bool in_suspend;
    bool shutdown;
    struct amdgpu_gfx gfx;
    struct amdgpu_sched gpu_sched[1][2];
};
struct nmx_accel_vm_mapping { uint64_t va, size; struct nmx_accel_vm_mapping *next; };
struct nmx_accel_vm_bo { struct nmx_accel_vm_mapping *mappings; struct nmx_accel_vm_bo *next; };
struct nmx_accel_vm { struct amdgpu_device *adev; struct amdgpu_vm vm; struct nmx_accel_vm_bo *bos; };
static struct drm_gpu_scheduler scheduler;
static struct drm_gpu_scheduler *schedulers[] = { &scheduler };
static struct nmx_accel_vm_mapping mapped = { 0x100000, 0x1000, NULL };
static struct nmx_accel_vm_bo mapped_bo = { &mapped, NULL };
static struct nmx_accel_vm task_vm = { 0, { 0 }, &mapped_bo };
static struct amdgpu_device device = { true, false, false, { 2 }, {{{ schedulers, 1 }, { schedulers, 1 }}} };
static void *g_iopci = &device;
static int g_vm_lock, g_bo_lock;
static int mutex_lock_calls, mutex_unlock_calls;
static void mutex_lock(void *lock) { (void)lock; ++mutex_lock_calls; }
static void mutex_unlock(void *lock) { (void)lock; ++mutex_unlock_calls; }
struct amdgpu_device *adev_of(void *iopci) { return iopci == &device ? &device : NULL; }
static struct nmx_accel_vm *nmx_accel_vm_find_locked(uint64_t handle) {
    return handle == (uint64_t)(uintptr_t)&task_vm ? &task_vm : NULL;
}
int job_alloc_calls, job_submit_calls, job_free_calls;
static struct dma_fence submitted_fence = { 1 };
int amdgpu_job_alloc(struct amdgpu_device *adev, struct amdgpu_vm *vm,
                     struct drm_sched_entity *entity, void *owner, unsigned int num_ibs,
                     struct amdgpu_job **job) {
    (void)adev; (void)vm; (void)entity; (void)owner;
    assert(num_ibs == 1); ++job_alloc_calls;
    static struct amdgpu_job allocated;
    *job = &allocated; return 0;
}
struct dma_fence *amdgpu_job_submit(struct amdgpu_job *job) {
    ++job_submit_calls; assert(job != NULL); assert(job->num_ibs == 1);
    assert(job->ibs[0].gpu_addr == 0x100100 && job->ibs[0].length_dw == 4);
    return &submitted_fence;
}
void amdgpu_job_free(struct amdgpu_job *job) { assert(job != NULL); ++job_free_calls; }
'''
HARNESS += gate + "\n" + client + "\n"
HARNESS += r'''
static void assert_refused(uint64_t vm, uint32_t ring, uint64_t ib, uint32_t dw, int want) {
    uint64_t fence = 0xdead;
    assert(nmx_accel_bridge_client_submit(vm, ring, ib, dw, &fence) == want);
    assert(fence == 0);
    assert(job_alloc_calls == 0 && job_submit_calls == 0 && job_free_calls == 0);
}
int main(void) {
    task_vm.adev = &device;
    /* Device gates precede shape checks. */
    g_iopci = NULL;
    assert_refused((uint64_t)(uintptr_t)&task_vm, 0, 0x100100, 4, -ENODEV);
    g_iopci = &device;
    device.accel_working = false;
    assert_refused((uint64_t)(uintptr_t)&task_vm, 0, 0x100100, 4, -ENODEV);
    device.accel_working = true;
    device.in_suspend = true;
    assert_refused((uint64_t)(uintptr_t)&task_vm, 0, 0x100100, 4, -EBUSY);
    device.in_suspend = false;
    /* Unknown VM, ring, alignment, zero length, and overflow are rejected. */
    assert_refused(1, 0, 0x100100, 4, -EINVAL);
    assert_refused((uint64_t)(uintptr_t)&task_vm, 2, 0x100100, 4, -EINVAL);
    assert_refused((uint64_t)(uintptr_t)&task_vm, 0, 0x100102, 4, -EINVAL);
    assert_refused((uint64_t)(uintptr_t)&task_vm, 0, 0x100100, 0, -EINVAL);
    assert_refused((uint64_t)(uintptr_t)&task_vm, 0, UINT64_MAX - 3, 1, -EINVAL);
    /* Mapping containment holds, but no client job may be queued before lifetime/VMID setup. */
    assert_refused((uint64_t)(uintptr_t)&task_vm, 0, 0x100ffc, 2, -ENOENT);
    assert_refused((uint64_t)(uintptr_t)&task_vm, 0, 0x100100, 4, -ENOTSUP);
    puts("PASS: client VM scheduler submit remains fail-closed until VMID/PASID/lifetime setup");
    return 0;
}
'''

with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    source = path / "vm_submit.c"
    source.write_text(HARNESS)
    subprocess.run(["clang", "-std=c2x", "-Wall", "-Wextra", "-Werror", str(source),
                    "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
