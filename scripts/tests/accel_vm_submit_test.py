"""Phase D host contract for the VM-aware client submit bridge (fail-closed).

nmx_accel_bridge_client_submit is the only client-work entry point. No task VM, bo_va mapping record, scheduler
entity, or job lifetime is verified yet (Phase B/C are fail-closed), so the function refuses every shape-valid
request with -ENOTSUP after its gates and shape checks. This test compiles the real bridge bodies against mocked
device state and amdgpu counters and proves: device gates precede every shape check; zero/misaligned/overflowing
IB and out-of-range rings or VM handles are rejected; a shape-valid IB is refused without an unmapped-range proof;
no amdgpu call (job alloc, job submit, IB schedule, VM update) and no fence/job is ever produced; the pinned
amdgpu_job_alloc argument order is recorded for the live path; and no IOKit caller routes client work into it.
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
KERNEL_SOURCES = [
    (ROOT / "Raphaeli/Kernel" / name).read_text()
    for name in ("nmx_accel.cpp", "nmx_accel_uc.cpp", "nmx_accel.h", "nmx_kext.cpp")
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

# Fail-closed: no amdgpu call, no raw submit, no NULL-job IB schedule, and no job/fence is produced.
assert not re.search(r"\bamdgpu_\w+\s*\(", client), "client submit must not reach amdgpu before a verified lifetime"
assert "nmx_accel_bridge_submit" not in client and "amdgpu_ib_schedule" not in client
assert "amdgpu_job_submit" not in client and "dma_fence" not in client

# Device gates run first, then shape checks, then refusal.
assert client.index("nmx_accel_bridge_vm_gate(") < client.index("-EINVAL")
assert client.index("nmx_accel_bridge_vm_gate(") < client.index("-ENOTSUP")
assert "adev->in_suspend || adev->shutdown" in gate and "-ENODEV" in gate and "-EBUSY" in gate

# Pinned amdgpu_job_alloc order for the live path: (adev, vm, entity, owner, num_ibs, job).
job_alloc = " ".join(AMDGPU_JOB_H[AMDGPU_JOB_H.index("int amdgpu_job_alloc("):AMDGPU_JOB_H.index("int amdgpu_job_alloc_with_ib(")].split())
assert job_alloc == ("int amdgpu_job_alloc(struct amdgpu_device *adev, struct amdgpu_vm *vm, "
                     "struct drm_sched_entity *entity, void *owner, unsigned int num_ibs, struct amdgpu_job **job);")

# No IOKit caller reaches the client submit yet: the client-test gate is not wired.
for source in KERNEL_SOURCES:
    assert "nmx_accel_bridge_client_submit" not in source

HARNESS = r'''
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
typedef uint64_t u64;
struct amdgpu_vm { int unused; };
struct amdgpu_job { int unused; };
struct amdgpu_ib { int unused; };
struct amdgpu_ring { int unused; };
struct drm_sched_entity { int unused; };
struct dma_fence { int unused; };
struct amdgpu_gfx { unsigned num_gfx_rings; };
struct amdgpu_device { bool accel_working; bool in_suspend; bool shutdown; struct amdgpu_gfx gfx; };
static struct amdgpu_device device = { true, false, false, { 2 } };
static void *g_iopci = &device;
struct amdgpu_device *adev_of(void *iopci) { return iopci == &device ? &device : NULL; }
int job_alloc_calls, job_submit_calls, ib_schedule_calls, vm_update_calls, job_free_calls, fence_put_calls;
int amdgpu_job_alloc(struct amdgpu_device *adev, struct amdgpu_vm *vm, struct drm_sched_entity *entity,
                     void *owner, unsigned int num_ibs, struct amdgpu_job **job) {
    (void)adev; (void)vm; (void)entity; (void)owner; (void)num_ibs; (void)job; ++job_alloc_calls; return 0;
}
struct dma_fence *amdgpu_job_submit(struct amdgpu_job *job) { (void)job; ++job_submit_calls; return NULL; }
int amdgpu_ib_schedule(struct amdgpu_ring *ring, unsigned num_ibs, struct amdgpu_ib *ibs,
                       struct amdgpu_job *job, struct dma_fence **f) {
    (void)ring; (void)num_ibs; (void)ibs; (void)job; (void)f; ++ib_schedule_calls; return 0;
}
int amdgpu_vm_update_pdes(struct amdgpu_device *adev, struct amdgpu_vm *vm, bool immediate) {
    (void)adev; (void)vm; (void)immediate; ++vm_update_calls; return 0;
}
void amdgpu_job_free(struct amdgpu_job *job) { (void)job; ++job_free_calls; }
void dma_fence_put(struct dma_fence *f) { (void)f; ++fence_put_calls; }
'''
HARNESS += gate + "\n" + client + "\n"
HARNESS += r'''
static void assert_no_amdgpu_calls(void) {
    assert(job_alloc_calls == 0 && job_submit_calls == 0 && ib_schedule_calls == 0);
    assert(vm_update_calls == 0 && job_free_calls == 0 && fence_put_calls == 0);
}
static void assert_refused(uint64_t vm, uint32_t ring, uint64_t ib, uint32_t dw, int want) {
    uint64_t fence = 0xdead;
    assert(nmx_accel_bridge_client_submit(vm, ring, ib, dw, &fence) == want);
    assert(fence == 0);
    assert_no_amdgpu_calls();
}
int main(void) {
    /* device gates precede every shape check and produce no fence */
    g_iopci = NULL;
    assert_refused(0, 9, 0, 0, -ENODEV);
    assert_refused(1, 0, 0x100000, 4, -ENODEV);
    g_iopci = &device;
    device.accel_working = false;
    assert_refused(1, 0, 0x100000, 4, -ENODEV);
    device.accel_working = true;
    device.in_suspend = true;
    assert_refused(1, 0, 0x100000, 4, -EBUSY);
    device.in_suspend = false;
    device.shutdown = true;
    assert_refused(1, 0, 0x100000, 4, -EBUSY);
    device.shutdown = false;
    /* wrong VM handle, zero or misaligned IB, zero dwords */
    assert_refused(0, 0, 0x100000, 4, -EINVAL);
    assert_refused(1, 0, 0, 4, -EINVAL);
    assert_refused(1, 0, 0x100000, 0, -EINVAL);
    assert_refused(1, 0, 0x100002, 4, -EINVAL);
    /* wrong ring: ring == num_gfx_rings and beyond are out of bounds */
    assert_refused(1, 2, 0x100000, 4, -EINVAL);
    assert_refused(1, UINT32_MAX, 0x100000, 4, -EINVAL);
    /* IB address + length overflow the 64-bit VA space */
    assert_refused(1, 0, UINT64_MAX - 15, 4, -EINVAL);
    assert_refused(1, 0, UINT64_MAX - 3, 1, -EINVAL);
    assert_refused(1, 0, UINT64_MAX - 0x100, UINT32_MAX, -EINVAL);
    /* shape-valid IB: no mapping record proves containment, so it is refused before any amdgpu call */
    assert_refused(1, 0, 0x100000, 4, -ENOTSUP);
    assert_refused(1, 1, 0x100000, UINT32_MAX, -ENOTSUP);
    uint64_t fence = 0xdead;
    assert(nmx_accel_bridge_client_submit(1, 0, 0x100000, 4, NULL) == -ENOTSUP);
    assert(fence == 0xdead);
    assert_no_amdgpu_calls();
    puts("PASS: fail-closed VM-aware client submit: device gates, handle/ring/IB shape, overflow, no amdgpu call, no fence");
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
