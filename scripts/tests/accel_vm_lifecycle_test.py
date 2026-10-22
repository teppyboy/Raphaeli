"""Host contract for the fail-closed per-task GPU VM bridge (Phase B).

No task VM is created yet: the pinned amdgpu_vm_init/amdgpu_vm_fini lifetime is not bound to a verified
RaphaeliTask hook (IOAccelTask declares no destroy/free slot), so the bridge refuses every VM operation.
This test compiles the real bridge bodies against mocked device state and amdgpu counters and proves:
create passes the device gates, refuses with no handle and no amdgpu call; destroy/map/unmap refuse
unknown handles (double destroy and teardown included) without touching amdgpu; and no file-scope VM exists.
"""
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "Raphaeli/Override/src/nmx_accel_bridge.c").read_text()
KMS = (ROOT / "kpi/drm-kmod/drivers/gpu/drm/amd/amdgpu/amdgpu_kms.c").read_text()
VM_SOURCE = (ROOT / "kpi/drm-kmod/drivers/gpu/drm/amd/amdgpu/amdgpu_vm.c").read_text()
XCP = (ROOT / "kpi/drm-kmod/drivers/gpu/drm/amd/amdgpu/amdgpu_xcp.c").read_text()
UMSCH = (ROOT / "kpi/drm-kmod/drivers/gpu/drm/amd/amdgpu/amdgpu_umsch_mm.c").read_text()
DEVICE = (ROOT / "kpi/drm-kmod/drivers/gpu/drm/amd/amdgpu/amdgpu_device.c").read_text()
VM_FUNCTIONS = (
    "nmx_accel_bridge_vm_create",
    "nmx_accel_bridge_vm_destroy",
    "nmx_accel_bridge_vm_map",
    "nmx_accel_bridge_vm_unmap",
)


def function(name, return_type="int"):
    return source_function(SOURCE, return_type + " " + name + "(")


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


# Pin the real amdgpu lifecycle rather than inferring it from the fail-closed bridge.
open_kms = source_function(KMS, "int amdgpu_driver_open_kms(")
open_steps = (
    "pasid = amdgpu_pasid_alloc(16);",
    "r = amdgpu_xcp_open_device(adev, fpriv, file_priv);",
    "r = amdgpu_vm_init(adev, &fpriv->vm, fpriv->xcp_id);",
    "r = amdgpu_vm_set_pasid(adev, &fpriv->vm, pasid);",
)
assert all(step in open_kms for step in open_steps)
assert [open_kms.index(step) for step in open_steps] == sorted(open_kms.index(step) for step in open_steps)
assert "if (pasid < 0)" in open_kms and "pasid = 0;" in open_kms
# DRM's permissive no-PASID fallback is not a task-VM policy: task creation must fail if identity cannot be allocated.
pasid_fallback = open_kms[open_kms.index("if (pasid < 0)"):open_kms.index("r = amdgpu_xcp_open_device")]
assert "pasid = 0;" in pasid_fallback and "return" not in pasid_fallback

postclose = source_function(KMS, "void amdgpu_driver_postclose_kms(")
close_steps = (
    "pasid = fpriv->vm.pasid;",
    "pd = amdgpu_bo_ref(fpriv->vm.root.bo);",
    "amdgpu_vm_fini(adev, &fpriv->vm);",
    "amdgpu_pasid_free_delayed(pd->tbo.base.resv, pasid);",
)
assert all(step in postclose for step in close_steps)
assert [postclose.index(step) for step in close_steps] == sorted(postclose.index(step) for step in close_steps)

vm_init = source_function(VM_SOURCE, "int amdgpu_vm_init(")
assert "r = amdgpu_vm_init_entities(adev, vm);" in vm_init
assert "r = amdgpu_vm_pt_create(adev, vm, adev->vm_manager.root_level," in vm_init
assert "false, &root, xcp_id);" in vm_init
# Failed init has internal rollback; DRM open also finalizes on post-init failures.
assert "goto error_free_delayed;" in vm_init and "error_free_delayed:" in vm_init
assert "error_vm:" in open_kms and "amdgpu_vm_fini(adev, &fpriv->vm);" in open_kms
vm_fini = source_function(VM_SOURCE, "void amdgpu_vm_fini(")
assert "amdgpu_vm_set_pasid(adev, vm, 0);" in vm_fini
assert "amdgpu_vm_pt_free_root(adev, vm);" in vm_fini
assert "amdgpu_vm_fini_entities(vm);" in vm_fini
vm_manager_fini = source_function(VM_SOURCE, "void amdgpu_vm_manager_fini(")
assert "WARN_ON(!xa_empty(&adev->vm_manager.pasids));" in vm_manager_fini

xcp_open = source_function(XCP, "int amdgpu_xcp_open_device(")
assert "fpriv->xcp_id = AMDGPU_XCP_NO_PARTITION;" in xcp_open
assert "fpriv->xcp_id = i;" in xcp_open
assert "fpriv->vm.mem_id = fpriv->xcp_id == AMDGPU_XCP_NO_PARTITION ? -1 :" in xcp_open
assert "if (!adev->xcp_mgr)" in xcp_open and "return 0;" in xcp_open
assert "if (file_priv->minor == adev->xcp_mgr->xcp[i].ddev->render)" in xcp_open
assert "if (adev->xcp_mgr->xcp[i].valid == FALSE)" in xcp_open

fini_hw = source_function(DEVICE, "void amdgpu_device_fini_hw(")
fini_sw = source_function(DEVICE, "void amdgpu_device_fini_sw(")
assert "adev->shutdown = true;" in fini_hw
assert "amdgpu_device_ip_fini(adev);" in fini_sw
assert "adev->accel_working = false;" in fini_sw

# UMSCH's private selftest has its own VM and PASID, but is not a task/fpriv model.
ums_setup = source_function(UMSCH, "static int setup_umsch_mm_test(")
ums_cleanup = source_function(UMSCH, "static void cleanup_umsch_mm_test(")
assert "amdgpu_vm_init(adev, test->vm, -1);" in ums_setup
assert "amdgpu_pasid_alloc(16);" in ums_setup
assert "amdgpu_vm_set_pasid" not in ums_setup + ums_cleanup
assert "fpriv" not in ums_setup + ums_cleanup
assert "amdgpu_pasid_free(test->pasid);" in ums_cleanup
assert "amdgpu_vm_fini(adev, test->vm);" in ums_cleanup


# Static contract: the fail-closed bodies never reach amdgpu, the raw ring-test submit, or a client flag.
for name in VM_FUNCTIONS:
    body = function(name)
    assert not re.search(r"\bamdgpu_\w+\s*\(", body), name + " must not call amdgpu before a verified lifetime"
    assert "nmx_accel_bridge_submit" not in body and "amdgpu_ib_schedule" not in body, name
assert not re.search(r"^(?:static\s+)?struct\s+amdgpu_vm\b", SOURCE, re.M), "no file-scope (global) amdgpu_vm"
assert "raphaeli-accel-client-test" not in SOURCE, "client test flag must stay absent"

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
#define AMDGPU_VA_RESERVED_TOP (6ULL << 20)
struct amdgpu_vm_manager { uint64_t max_pfn; };
struct amdgpu_device { bool accel_working; bool in_suspend; bool shutdown; struct amdgpu_vm_manager vm_manager; };
struct amdgpu_vm { int unused; };
struct amdgpu_device device = { true, false, false, { 1ULL << 20 } };
void *g_iopci = &device;
struct amdgpu_device *adev_of(void *iopci) { return iopci == &device ? &device : NULL; }
int vm_init_calls, vm_fini_calls, bo_map_calls, bo_unmap_calls;
int amdgpu_vm_init(struct amdgpu_device *a, struct amdgpu_vm *vm, int32_t x) { (void)a; (void)vm; (void)x; ++vm_init_calls; return 0; }
void amdgpu_vm_fini(struct amdgpu_device *a, struct amdgpu_vm *vm) { (void)a; (void)vm; ++vm_fini_calls; }
int amdgpu_vm_bo_map(struct amdgpu_device *a, struct amdgpu_vm *vm, u64 va, u64 off, u64 size, u64 flags) { (void)a; (void)vm; (void)va; (void)off; (void)size; (void)flags; ++bo_map_calls; return 0; }
int amdgpu_vm_bo_unmap(struct amdgpu_device *a, struct amdgpu_vm *vm, u64 va) { (void)a; (void)vm; (void)va; ++bo_unmap_calls; return 0; }
'''
# The map/unmap bodies call the static device-gate and range helpers; compile them with the public bodies.
HARNESS += function("nmx_accel_bridge_vm_gate", "static int")
HARNESS += function("nmx_accel_bridge_vm_check_range", "static int")
for name in VM_FUNCTIONS:
    HARNESS += function(name)
HARNESS += r'''
static void assert_no_amdgpu_calls(void) {
    assert(vm_init_calls == 0 && vm_fini_calls == 0 && bo_map_calls == 0 && bo_unmap_calls == 0);
}
int main(void) {
    u64 vm = 0xdead;
    /* create: device gates precede everything and refuse without a handle */
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
    /* a gated-in create is still refused: no verified task lifetime, so no VM and no leaked handle */
    vm = 0xdead;
    assert(nmx_accel_bridge_vm_create(&vm) == -ENOTSUP && vm == 0);
    assert_no_amdgpu_calls();
    /* destroy: no record exists, so every handle (including a repeated one) is unknown */
    assert(nmx_accel_bridge_vm_destroy(0) == -EINVAL);
    assert(nmx_accel_bridge_vm_destroy(1) == -EINVAL);
    assert(nmx_accel_bridge_vm_destroy(1) == -EINVAL);
    /* map/unmap during teardown or for unknown handles never reach amdgpu */
    assert(nmx_accel_bridge_vm_map(0, 1, 0x100000, 0, 4096, 0) == -EINVAL);
    assert(nmx_accel_bridge_vm_map(1, 1, 0x100000, 0, 4096, 0) == -ENOTSUP);
    assert(nmx_accel_bridge_vm_unmap(1, 1, 0x100000, 4096) == -ENOTSUP);
    assert_no_amdgpu_calls();
    puts("PASS: fail-closed task VM contract: device gates, create rollback, double destroy, teardown, no global VM");
    return 0;
}
'''

with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    source = path / "vm_lifecycle.c"
    source.write_text(HARNESS)
    subprocess.run(["clang", "-std=c2x", "-Wall", "-Wextra", "-Werror", str(source),
                    "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
