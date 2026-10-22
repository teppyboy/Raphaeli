"""Focused host contract for the mapped AMD GPU scheduler submit path."""
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

# The live path must reject malformed requests before touching amdgpu, prove mapped containment,
# and use the pinned scheduler/job APIs rather than the raw NULL-job ring-test path.
assert client.index("nmx_accel_bridge_vm_gate(") < client.index("-EINVAL")
assert "ib_addr >= mapping->va" in client and "mapping->size - ib_size" in client
assert "adev->gpu_sched[AMDGPU_HW_IP_GFX][AMDGPU_RING_PRIO_DEFAULT]" in client
assert "drm_sched_entity_init" in client
assert "amdgpu_job_alloc(adev, &task_vm->vm, &g_client_entity, task_vm, 1, &job)" in client
assert "job->ibs[0].gpu_addr = ib_addr" in client
assert "job->ibs[0].length_dw = ib_dw" in client
assert "amdgpu_job_submit(job)" in client
assert "amdgpu_ib_schedule" not in client
assert "amdgpu_job_submit(job);" in client

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
static struct drm_sched_entity g_client_entity;
static struct amdgpu_device *g_client_entity_adev;
static int g_vm_lock, g_bo_lock;
static int mutex_lock_calls, mutex_unlock_calls;
static void mutex_lock(void *lock) { (void)lock; ++mutex_lock_calls; }
static void mutex_unlock(void *lock) { (void)lock; ++mutex_unlock_calls; }
struct amdgpu_device *adev_of(void *iopci) { return iopci == &device ? &device : NULL; }
static struct nmx_accel_vm *nmx_accel_vm_find_locked(uint64_t handle) {
    return handle == (uint64_t)(uintptr_t)&task_vm ? &task_vm : NULL;
}
int drm_sched_entity_init(struct drm_sched_entity *entity, int priority,
                          struct drm_gpu_scheduler **sched, unsigned num,
                          void *guilty) {
    (void)entity; (void)priority; (void)sched; (void)guilty;
    assert(num == 1); return 0;
}
#define DRM_SCHED_PRIORITY_NORMAL 0
#define AMDGPU_HW_IP_GFX 0
#define AMDGPU_RING_PRIO_DEFAULT 1
int job_alloc_calls, job_submit_calls, job_free_calls, entity_init_calls;
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
    /* Range containment is whole-IB, not just start-address validation. */
    assert_refused((uint64_t)(uintptr_t)&task_vm, 0, 0x100ffc, 2, -ENOENT);
    /* A mapped IB becomes a real scheduler job and returns its fence. */
    uint64_t fence = 0;
    assert(nmx_accel_bridge_client_submit((uint64_t)(uintptr_t)&task_vm, 0, 0x100100, 4, &fence) == 0);
    assert(fence == (uint64_t)(uintptr_t)&submitted_fence);
    assert(job_alloc_calls == 1 && job_submit_calls == 1 && job_free_calls == 0);
    puts("PASS: mapped VM scheduler submit: gates, containment, pinned job allocation, IB, fence");
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
