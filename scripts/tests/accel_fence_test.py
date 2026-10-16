"""Compile actual bridge wait/selftest bodies with host fence/BO mocks."""
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "Raphaeli/Override/src/nmx_accel_bridge.c").read_text()


def function(name):
    start = SOURCE.index("int " + name + "(")
    opening = SOURCE.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (SOURCE[end] == "{") - (SOURCE[end] == "}")
        end += 1
    return SOURCE[start:end]


HARNESS = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <errno.h>
#include <stdbool.h>
typedef uint64_t u64;
typedef int kern_return_t;
enum { KERN_SUCCESS = 0, KERN_OPERATION_TIMED_OUT = 49 };
enum { AMDGPU_GEM_DOMAIN_GTT = 2, AMDGPU_GEM_DOMAIN_VRAM = 4 };
#define PACKET3(a,b) 0
#define PACKET3_NOP 0
typedef struct dma_fence { int unused; } dma_fence;
typedef struct amdgpu_device { int unused; } amdgpu_device;
typedef struct amdgpu_bo { int unused; } amdgpu_bo;
dma_fence fence;
amdgpu_device device;
amdgpu_bo buffer;
void *g_iopci = &device;
long wait_result;
int fence_status, put_count, status_count, ib_frees, vram_frees, submit_result;
bool enabled = true;
uint32_t memory[1024];
bool PE_parse_boot_argn(const char *, int *value, unsigned) { *value = enabled; return true; }
amdgpu_device *adev_of(void *) { return &device; }
unsigned msecs_to_jiffies(unsigned ms) { return ms; }
long dma_fence_wait_timeout(dma_fence *, bool, unsigned) { return wait_result; }
int dma_fence_get_status(dma_fence *f) { (void)f; ++status_count; return fence_status; }
void dma_fence_put(dma_fence *f) { (void)f; ++put_count; }
int amdgpu_bo_create_kernel(amdgpu_device *, u64, unsigned, unsigned, amdgpu_bo **bo, u64 *addr, void **cpu) {
    *bo = &buffer; *addr = 4096; *cpu = memory; return 0;
}
void amdgpu_bo_free_kernel(amdgpu_bo **, u64 *, void **) { ++ib_frees; }
int nmx_accel_bridge_alloc(u64, u64, unsigned, u64 *bo, u64 *addr, void **cpu) {
    *bo = 1; *addr = 8192; *cpu = memory; return 0;
}
u64 nmx_accel_bridge_dmap(u64) { return 8192; }
void nmx_accel_bridge_free(u64, u64, void *) { ++vram_frees; }
int nmx_xnu_accel_ring_submit(unsigned, u64, unsigned, u64 *value) {
    *value = (uintptr_t)&fence; return submit_result;
}
'''
HARNESS += function("nmx_accel_bridge_fence_wait")
HARNESS += r'''
int nmx_xnu_accel_fence_wait(u64 value, unsigned ms) {
    int result = nmx_accel_bridge_fence_wait(value, ms);
    return result == 0 ? KERN_SUCCESS : result == -ETIME ? KERN_OPERATION_TIMED_OUT : 1;
}
'''
HARNESS += function("nmx_accel_selftest")
HARNESS += r'''
int main() {
    const u64 handle = (uintptr_t)&fence;
    assert(nmx_accel_bridge_fence_wait(0, 10) == -EINVAL);
    assert(put_count == 0);
    wait_result = 0; fence_status = 1;
    assert(nmx_accel_bridge_fence_wait(handle, 0) == -ETIME);
    assert(put_count == 1 && status_count == 0);
    wait_result = -EINTR;
    assert(nmx_accel_bridge_fence_wait(handle, 10) == -EINTR);
    assert(put_count == 2 && status_count == 0);
    wait_result = 1; fence_status = -EIO;
    assert(nmx_accel_bridge_fence_wait(handle, 10) == -EIO);
    assert(put_count == 3 && status_count == 1);
    fence_status = 0;
    assert(nmx_accel_bridge_fence_wait(handle, 10) == -ETIME);
    fence_status = 1;
    assert(nmx_accel_bridge_fence_wait(handle, 10) == 0);
    assert(put_count == 5 && status_count == 3);
    assert(nmx_accel_selftest() == 0);
    assert(ib_frees == 1 && vram_frees == 1);
    wait_result = 0;
    assert(nmx_accel_selftest() != 0);
    assert(ib_frees == 1 && vram_frees == 2);
    wait_result = -EINTR;
    assert(nmx_accel_selftest() != 0);
    assert(ib_frees == 1 && vram_frees == 3);
    wait_result = 1; fence_status = -EIO;
    assert(nmx_accel_selftest() != 0);
    assert(ib_frees == 1 && vram_frees == 4);
    submit_result = 1;
    assert(nmx_accel_selftest() != 0);
    assert(ib_frees == 2 && vram_frees == 5);
    enabled = false;
    assert(nmx_accel_selftest() == 0);
    assert(ib_frees == 2 && vram_frees == 5);
    puts("PASS: real fence/selftest bodies, timeout/error propagation, in-flight IB lifetime");
}
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    source = path / "fence.c"
    source.write_text(HARNESS)
    subprocess.run(["clang", "-std=c2x", "-Wall", "-Wextra", "-Werror", str(source),
                    "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
