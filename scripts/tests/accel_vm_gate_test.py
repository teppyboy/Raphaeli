"""Static Phase A contract for the fail-closed acceleration baseline.

This test intentionally does not add or exercise a VM/client implementation.  It
proves that the existing raw ring path is still only the boot-arg selftest and
records the boot-arg gate required before a future client path may be armed.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BRIDGE = (ROOT / "Raphaeli/Override/src/nmx_accel_bridge.c").read_text()
UC = (ROOT / "Raphaeli/Kernel/nmx_accel_uc.cpp").read_text()
ACCEL = (ROOT / "Raphaeli/Kernel/nmx_accel.cpp").read_text()
KERNEL_SOURCES = [path for path in (ROOT / "Raphaeli/Kernel").rglob("*")
                  if path.suffix in {".c", ".cc", ".cpp", ".cxx"}]
KEXT = (ROOT / "Raphaeli/Kernel/nmx_kext.cpp").read_text()
JOB_H = (ROOT / "kpi/drm-kmod/drivers/gpu/drm/amd/amdgpu/amdgpu_job.h").read_text()
PORT_HEADERS = [
    (ROOT / "Raphaeli/Compat/include/nmx_port.h").read_text(),
    (ROOT / "Raphaeli/Compat/include/nmxxnu/nmx_port.h").read_text(),
]


def function_body(source, signature):
    """Return one C/C++ function body, including nested blocks safely."""
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[opening:end]


# The raw bridge retains amdgpu's kernel ring-test shape: no job means no VM.
raw_submit = function_body(BRIDGE, "int nmx_accel_bridge_submit(")
assert "amdgpu_ib_schedule(gring, 1, &ib, NULL, &f)" in raw_submit
assert "no job and no VM" in BRIDGE  # keep the safety rationale discoverable in the source comment

# It has exactly one IOKit-side wrapper, and that wrapper is reached only by
# the explicit kernel selftest.  No vendor memory-map/client method may call it.
ring_wrapper = function_body(ACCEL, "extern \"C\" kern_return_t nmx_xnu_accel_ring_submit(")
assert ring_wrapper.count("nmx_accel_bridge_submit(") == 1
assert "nmx_accel_bridge_submit(" not in UC
# No IOAccel implementation may reach the client bridge until the private command
# ABI, task VM/job lifetime and a test-mode gate are verified.
assert all("nmx_accel_bridge_client_submit(" not in source.read_text()
           for source in KERNEL_SOURCES)
selftest = function_body(BRIDGE, "int nmx_accel_selftest(")
assert selftest.count("nmx_xnu_accel_ring_submit(") == 1
assert "nmx_xnu_accel_ring_submit(0, gpu_addr, 2, &fence)" in selftest
assert "nmx_xnu_accel_ring_submit(" not in UC

# Phase A has no client gate.  In particular, the explicit client-test flag
# must not be silently enabled by the existing AMD opt-in or by attach.
CLIENT_FLAG = "raphaeli-accel-client-test"
PRODUCTION_SOURCES = (BRIDGE, UC, ACCEL, KEXT)
assert all(CLIENT_FLAG not in source for source in PRODUCTION_SOURCES)
assert "raphaeli-amd" not in ACCEL  # this TU cannot turn client mode on at attach

# Keep the future gate's combinations executable as a test contract without
# creating a production parser.  Phase A has no implementation, so even the
# otherwise-valid final row remains disarmed by the absent client gate above.
def contract_allows_client_test(case):
    return all((case["amd_opt_in"], case["client_arg"], case["verified_device"],
                case["accel_working"], not case["suspended"], not case["teardown"],
                case["abi_verified"], case["validation_passed"]))


BOOT_CASES = [
    {"name": "no AMD opt-in", "amd_opt_in": False, "client_arg": False,
     "verified_device": True, "accel_working": True, "suspended": False,
     "teardown": False, "abi_verified": True, "validation_passed": True},
    {"name": "AMD only", "amd_opt_in": True, "client_arg": False,
     "verified_device": True, "accel_working": True, "suspended": False,
     "teardown": False, "abi_verified": True, "validation_passed": True},
    {"name": "client-test only", "amd_opt_in": False, "client_arg": True,
     "verified_device": True, "accel_working": True, "suspended": False,
     "teardown": False, "abi_verified": True, "validation_passed": True},
    {"name": "both flags, valid device", "amd_opt_in": True, "client_arg": True,
     "verified_device": True, "accel_working": True, "suspended": False,
     "teardown": False, "abi_verified": True, "validation_passed": True},
    {"name": "wrong device identity", "amd_opt_in": True, "client_arg": True,
     "verified_device": False, "accel_working": True, "suspended": False,
     "teardown": False, "abi_verified": True, "validation_passed": True},
    {"name": "suspended device", "amd_opt_in": True, "client_arg": True,
     "verified_device": True, "accel_working": True, "suspended": True,
     "teardown": False, "abi_verified": True, "validation_passed": True},
    {"name": "failed validation", "amd_opt_in": True, "client_arg": True,
     "verified_device": True, "accel_working": True, "suspended": False,
     "teardown": False, "abi_verified": True, "validation_passed": False},
]
for case in BOOT_CASES:
    allowed = contract_allows_client_test(case)
    assert allowed == (case["name"] == "both flags, valid device")
    # The Phase A implementation is deliberately absent, so none can arm now.
    assert CLIENT_FLAG not in " ".join(case)

# The family map hooks remain refusal paths until a task-owned VM mapping exists.
commit = function_body(UC, "bool RaphaeliMemoryMap::commitIntoGPUPageTable(")
update = function_body(UC, "bool RaphaeliMemoryMap::updateGPUPageTable()")
assert "return false;" in commit
assert update.strip() == "{ return false; }"
assert "nmx_xnu_accel_ring_submit" not in commit

# Both duplicate headers must agree on the approved Phase A ABI.  The working
# tree may contain unapproved VM declarations in only one copy; do not bless
# those declarations by requiring full-file equality in this baseline test.
SAFE_DECLARATIONS = (
    "void nmx_accel_bridge_device(void *iopci);",
    "int nmx_accel_bridge_submit(uint32_t ring, uint64_t ib_addr, uint32_t ib_dw, uint64_t *fence_out);",
    "int nmx_accel_bridge_fence_wait(uint64_t fence, uint32_t timeout_ms);",
    "int nmx_accel_bridge_free(uint64_t bo, uint64_t gpu_addr, void *cpu);",
    "int nmx_accel_selftest(void);",
)
for declaration in SAFE_DECLARATIONS:
    assert all(declaration in header for header in PORT_HEADERS)

# Compare only the approved common surface.  The first header currently has
# extra VM declarations from an unapproved later experiment; this test keeps
# that mismatch visible without making those declarations part of Phase A.
def safe_declarations(header):
    return tuple(line.strip() for line in header.splitlines()
                 if any(declaration in line for declaration in SAFE_DECLARATIONS))

assert safe_declarations(PORT_HEADERS[0]) == safe_declarations(PORT_HEADERS[1])
assert all("vm_" not in declaration for declaration in SAFE_DECLARATIONS)

# Preserve BO lifetime safety: reserve, optional kunmap, unpin, unreserve, unref.
free = function_body(BRIDGE, "int nmx_accel_bridge_free(")
order = ["amdgpu_bo_reserve", "amdgpu_bo_kunmap", "amdgpu_bo_unpin",
         "amdgpu_bo_unreserve", "amdgpu_bo_unref"]
positions = [free.index(token) for token in order]
assert positions == sorted(positions)

# A future VM-aware job must use the pinned amdgpu_job_alloc contract.
job_alloc = " ".join(JOB_H[JOB_H.index("int amdgpu_job_alloc("):JOB_H.index("int amdgpu_job_alloc_with_ib(")].split())
assert job_alloc == ("int amdgpu_job_alloc(struct amdgpu_device *adev, struct amdgpu_vm *vm, "
                     "struct drm_sched_entity *entity, void *owner, unsigned int num_ibs, struct amdgpu_job **job);")

print("PASS: Phase A raw-submit, fail-closed VM, boot-combination, and shared-header safety contract")
