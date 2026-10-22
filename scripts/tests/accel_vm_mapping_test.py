"""Phase C host contract for fail-closed BO/VA mapping.

Task VM handles come from the bridge-owned registry (accel_vm_lifecycle_test.py), but no bo_va record exists, so
no amdgpu_bo_va or mapping can be owned and map/unmap must refuse.  This test compiles the real bridge bodies against mocked device state and
proves the validation boundary that runs before any refusal: device gates, zero/overflow/misaligned VA and
size, the pinned reserved bottom/top and GMC hole, and offset overflow.  It also proves no amdgpu call, no
file-scope mapping record, and the unchanged BO free order used by teardown.
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
    start = SOURCE.index(return_type + " " + name + "(")
    opening = SOURCE.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (SOURCE[end] == "{") - (SOURCE[end] == "}")
        end += 1
    return SOURCE[start:end]


# The approved signatures are the plan's shape: amdgpu_vm_bo_map needs offset and flags.
MAP_SIGNATURE = ("int nmx_accel_bridge_vm_map(uint64_t vm, uint64_t bo, uint64_t va, uint64_t offset, "
                 "uint64_t size, uint64_t flags);")
UNMAP_SIGNATURE = "int nmx_accel_bridge_vm_unmap(uint64_t vm, uint64_t bo, uint64_t va, uint64_t size);"
for header in PORT_HEADERS:
    assert MAP_SIGNATURE in header
    assert UNMAP_SIGNATURE in header
assert MAP_SIGNATURE[:-1] + "\n{" in SOURCE or MAP_SIGNATURE[:-1] + " {" in SOURCE
assert UNMAP_SIGNATURE[:-1] + "\n{" in SOURCE or UNMAP_SIGNATURE[:-1] + " {" in SOURCE

map_body = function("nmx_accel_bridge_vm_map")
unmap_body = function("nmx_accel_bridge_vm_unmap")
gate = function("nmx_accel_bridge_vm_gate", "static int")
check_range = function("nmx_accel_bridge_vm_check_range", "static int")

# No amdgpu, submit, or BO call may be reachable before ownership is proven.
for name, body in (("map", map_body), ("unmap", unmap_body), ("gate", gate), ("check_range", check_range)):
    assert not re.search(r"\bamdgpu_\w+\s*\(", body), name
    assert "nmx_accel_bridge_submit" not in body and "amdgpu_ib_schedule" not in body, name

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
for name in ("AMDGPU_GPU_PAGE_MASK", "AMDGPU_GMC_HOLE_START", "AMDGPU_GMC_HOLE_END",
             "AMDGPU_VA_RESERVED_BOTTOM", "AMDGPU_VA_RESERVED_TOP", "max_pfn"):
    assert name in check_range, name

# Device gates precede VA checks; no VM/BO record exists at file scope.
assert gate.index("-ENODEV") < gate.index("-EBUSY")
assert "adev->in_suspend || adev->shutdown" in gate
assert map_body.index("nmx_accel_bridge_vm_gate(") < map_body.index("nmx_accel_bridge_vm_check_range(")
assert unmap_body.index("nmx_accel_bridge_vm_gate(") < unmap_body.index("nmx_accel_bridge_vm_check_range(")
assert not re.search(r"^(?:static\s+)?struct\s+amdgpu_(?:vm|bo_va)\b", SOURCE, re.M), "no file-scope VM or bo_va"
# Teardown keeps the BO free order: reserve, kunmap, unpin, unreserve, unref.
free = function("nmx_accel_bridge_free")
order = [free.index(token) for token in ("amdgpu_bo_reserve", "amdgpu_bo_kunmap", "amdgpu_bo_unpin",
                                         "amdgpu_bo_unreserve", "amdgpu_bo_unref")]
assert order == sorted(order)

HARNESS = r'''
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
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
struct amdgpu_vm_manager { uint64_t max_pfn; };
struct amdgpu_device {
    bool accel_working;
    bool in_suspend;
    bool shutdown;
    struct amdgpu_vm_manager vm_manager;
};
static struct amdgpu_device device = { true, false, false, { 1ULL << 20 } };
static void *g_iopci = &device;
struct amdgpu_device *adev_of(void *iopci) { return iopci == &device ? &device : NULL; }
'''
HARNESS += gate + "\n" + check_range + "\n" + map_body + "\n" + unmap_body
HARNESS += r'''
static void assert_map(uint64_t va, uint64_t offset, uint64_t size, int want) {
    assert(nmx_accel_bridge_vm_map(1, 2, va, offset, size, 0) == want);
}
int main(void) {
    const uint64_t usable_end = (device.vm_manager.max_pfn << AMDGPU_GPU_PAGE_SHIFT) - AMDGPU_VA_RESERVED_TOP;
    /* device gates precede every VA check */
    g_iopci = NULL;
    assert(nmx_accel_bridge_vm_map(1, 2, 0x100000, 0, 4096, 0) == -ENODEV);
    g_iopci = &device;
    device.accel_working = false;
    assert(nmx_accel_bridge_vm_unmap(1, 2, 0x100000, 4096) == -ENODEV);
    device.accel_working = true;
    device.in_suspend = true;
    assert(nmx_accel_bridge_vm_map(1, 2, 0, 1, 1, 0) == -EBUSY);
    device.in_suspend = false;
    device.shutdown = true;
    assert(nmx_accel_bridge_vm_unmap(1, 2, 0, 1) == -EBUSY);
    device.shutdown = false;
    /* zero size, overflow, misaligned VA/offset/size */
    assert_map(0x100000, 0, 0, -EINVAL);
    assert_map(UINT64_MAX - 4095, 0, 8192, -EINVAL);
    assert_map(0x100001, 0, 4096, -EINVAL);
    assert_map(0x100000, 0, 4097, -EINVAL);
    assert_map(0x100000, 1, 4096, -EINVAL);
    /* reserved bottom, GMC hole, hole crossing, and reserved top */
    assert_map(0, 0, 4096, -EINVAL);
    assert_map(AMDGPU_GMC_HOLE_START, 0, 4096, -EINVAL);
    assert_map(AMDGPU_GMC_HOLE_START - 4096, 0, 8192, -EINVAL);
    assert_map(usable_end, 0, 4096, -EINVAL);
    /* offset + size overflow */
    assert_map(0x100000, UINT64_MAX - 4095, 8192, -EINVAL);
    /* a valid range still refuses: no task VM/BO record exists to own a mapping */
    assert_map(0x100000, 0, 4096, -ENOTSUP);
    assert(nmx_accel_bridge_vm_map(0, 2, 0x100000, 0, 4096, 0) == -EINVAL);
    assert(nmx_accel_bridge_vm_map(1, 0, 0x100000, 0, 4096, 0) == -EINVAL);
    assert(nmx_accel_bridge_vm_unmap(1, 2, 0x100000, 4096) == -ENOTSUP);
    assert(nmx_accel_bridge_vm_unmap(1, 2, 0x100000, 0) == -EINVAL);
    assert(nmx_accel_bridge_vm_unmap(1, 2, 0x100001, 4096) == -EINVAL);
    puts("PASS: fail-closed BO/VA validation, device gates, reserved-range rules, no mapping record");
    return 0;
}
'''

with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    source = path / "vm_mapping.c"
    source.write_text(HARNESS)
    subprocess.run(["clang", "-std=c2x", "-Wall", "-Wextra", "-Werror", str(source),
                    "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
