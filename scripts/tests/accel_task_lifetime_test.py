"""Static contract for the current Sequoia IOAccelTask VM-lifetime gate.

This checks report evidence tokens and source state; it does not parse the ABI binary.
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HEADER = (ROOT / "Raphaeli/Kernel/nmx_accel.h").read_text()
UC = (ROOT / "Raphaeli/Kernel/nmx_accel_uc.cpp").read_text()
BRIDGE = (ROOT / "Raphaeli/Override/src/nmx_accel_bridge.c").read_text()
REPORT = (ROOT / "docs/reports/accel-vm-gate.md").read_text()
IMPLEMENTATION_SUFFIXES = {".c", ".cc", ".cpp", ".cxx"}


def strip_comments(text):
    return re.sub(r"/\*.*?\*/", "", text, flags=re.S)


def class_body(source, name):
    start = source.index("class " + name + " : public")
    opening = source.index("{", start)
    end = source.index("};", opening)
    return strip_comments(source[opening + 1:end])


def function_body(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[opening:end]


# The ABI evidence proves the family virtual exists; source still deliberately has no override.
body = class_body(HEADER, "RaphaeliTask")
assert "OSDeclareDefaultStructors(RaphaeliTask)" in body
assert "free" not in body
assert "~RaphaeliTask" not in body
assert "RaphaeliTask::free" not in UC

# No task free definition may be added outside the one task implementation source.
free_definition = re.compile(r"\bRaphaeliTask\s*::\s*free\s*\([^;{}]*\)\s*(?:const\s*)?\{")
for source_root in (ROOT / "Raphaeli/Kernel", ROOT / "Raphaeli/Override/src"):
    for source_path in sorted(source_root.rglob("*")):
        if source_path.suffix in IMPLEMENTATION_SUFFIXES and source_path.name != "nmx_accel_uc.cpp":
            assert not free_definition.search(source_path.read_text()), "RaphaeliTask::free defined outside nmx_accel_uc.cpp: " + str(source_path)

# The bridge rationale must distinguish the verified family free virtual from the port-detach release point.
assert "IOAccelTask::free" in REPORT
assert "nmx_accel_bridge_vm_release_all" in BRIDGE

# VM creation is owned by the bridge: amdgpu_vm_init on a registry record, no handle before it succeeds.
create = function_body(BRIDGE, "int nmx_accel_bridge_vm_create(")
assert "amdgpu_vm_init(" in create
assert "*vm_out = 0;" in create

# Client submission remains fail-closed until the submit slice lands; map/unmap record real bo_va mappings.
body = function_body(BRIDGE, "int nmx_accel_bridge_client_submit(")
assert "return -ENOTSUP;" in body, "nmx_accel_bridge_client_submit must stay fail-closed"
for name in ("nmx_accel_bridge_vm_map", "nmx_accel_bridge_vm_unmap"):
    body = function_body(BRIDGE, "int " + name + "(")
    assert "amdgpu_vm_bo_map(" in body or "amdgpu_vm_bo_unmap(" in body, name + " must reach the bo_va table"

# Check report evidence tokens; exact binary ABI evidence was independently captured from the local KDK.
for text in (
    "KDK_15.7.8_24G824",
    "__ZTV11IOAccelTask",
    "__DATA,__const",
    "435168",
    "IOAccelTask::free",
    "0x393f0",
    "0x7a9b8",
    "0x7aa58",
    "0xa0",
    "raw qword index 20",
    "conventional slot index 18",
    "*0xa0(%rax)",
    "*0x18(%rax)",
    "OSObject::release",
    "first memory-map list at task",
    "second list at task `+0x200`",
    "map `+0x18`",
    "0x39511",
    "0x39520",
    "0x52a5c",
    "does **not** prove every vendor-map override's ordering",
    "0x39487",
    "allocGPUVirtualAddress",
    "freeGPUVirtualAddress",
    "no safe post-base callback",
    "releaseFromGPUPageTable",
    "object deallocation",
    "nmx_accel_bridge_vm_create",
    "amdgpu_vm_init",
    "amdgpu_vm_fini",
    "mapping-cleanup ordering",
    "amdgpu device lifetime synchronization",
    "PASID allocation",
    "XCP selection",
    "Outstanding map/job/fence cleanup",
    "Family-vs-bridge teardown ordering",
    "-ENOTSUP",
):
    assert text in REPORT, "report missing: " + text

print("PASS: IOAccelTask::free exists in Sequoia ABI; task VM create/destroy bridge-owned; map records bo_va; client submit fail-closed")
