"""Host contract for nmx_accel_bridge_free: kunmap runs for a kmapped BO even when the caller passes a NULL CPU.

RaphaeliVidMemory::deallocPhysical frees with cpu == NULL, but nmx_accel_bridge_alloc creates the BO through
amdgpu_bo_create_kernel with a CPU mapping, so the BO is kmapped. Pinned amdgpu_bo_kunmap is a no-op when no kmap
exists (amdgpu_object.c: if (bo->kmap.bo)), so the free must always call it before unpin. This test compiles the
real nmx_accel_bridge_free body against mocks and records the teardown sequence.
"""
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
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef uint64_t u64;
struct amdgpu_bo { int unused; };
struct amdgpu_bo buffer;
int reserve_result;
char trace[16];
int trace_len;
static void record(char op) { trace[trace_len++] = op; trace[trace_len] = 0; }
int amdgpu_bo_reserve(struct amdgpu_bo *bo, bool no_intr) { (void)bo; (void)no_intr; record('r'); return reserve_result; }
void amdgpu_bo_kunmap(struct amdgpu_bo *bo) { (void)bo; record('k'); }
void amdgpu_bo_unpin(struct amdgpu_bo *bo) { (void)bo; record('p'); }
void amdgpu_bo_unreserve(struct amdgpu_bo *bo) { (void)bo; record('u'); }
void amdgpu_bo_unref(struct amdgpu_bo **bo) { (void)bo; record('f'); }
'''
HARNESS += function("nmx_accel_bridge_free")
HARNESS += r'''
int main() {
    const u64 bo = (uintptr_t)&buffer;
    /* uc deallocPhysical shape: cpu == NULL on a kmapped BO, so kunmap must still run before unpin */
    reserve_result = 0;
    assert(nmx_accel_bridge_free(bo, 8192, NULL) == 0);
    assert(strcmp(trace, "rkpuf") == 0);
    /* active BO: reserve refused, nothing torn down, caller keeps ownership */
    trace_len = 0; trace[0] = 0;
    reserve_result = -EBUSY;
    assert(nmx_accel_bridge_free(bo, 8192, NULL) == -EBUSY);
    assert(strcmp(trace, "r") == 0);
    /* null handle: no-op */
    trace_len = 0; trace[0] = 0;
    assert(nmx_accel_bridge_free(0, 0, NULL) == 0);
    assert(trace_len == 0);
    puts("PASS: free kunmaps a kmapped BO with NULL CPU out; active BO refused without teardown");
}
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    source = path / "bo_free.c"
    source.write_text(HARNESS)
    subprocess.run(["clang", "-std=c2x", "-Wall", "-Wextra", "-Werror", str(source),
                    "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
