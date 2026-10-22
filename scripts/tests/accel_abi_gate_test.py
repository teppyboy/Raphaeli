"""Host ABI gate for the IOAccel command decoder (Phase E, Task 5).

Fails if a decoder or client submit path appears in production sources without the exact per-build ABI evidence
recorded in docs/reports/accel-abi-evidence.md. Today that evidence is absent, so the gate also asserts that no
decoder markers exist. The check is static: it proves nothing about IOAccel runtime semantics.
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PRODUCTION = [
    ROOT / "Raphaeli/Kernel/nmx_accel.cpp",
    ROOT / "Raphaeli/Kernel/nmx_accel.h",
    ROOT / "Raphaeli/Kernel/nmx_accel_uc.cpp",
    ROOT / "Raphaeli/Kernel/nmx_kext.cpp",
    ROOT / "Raphaeli/Override/src/nmx_accel_bridge.c",
]
EVIDENCE = ROOT / "docs/reports/accel-abi-evidence.md"
REPORT = ROOT / "docs/reports/accel-abi-gate.md"

# Markers of a decoder or client submit path: family token/command walk hooks, the stream-info type, a client flag.
DECODER_MARKERS = (
    r"processDataBuffers",
    r"beginCommandStream",
    r"endCommandStream",
    r"bindResource\s*\(",
    r"IOAccelCommandStreamInfo",
    r"submit_command_buffers",
    r"raphaeli-accel-client-test",
    r"nmx_accel_decode",
)
sources = {path: path.read_text() for path in PRODUCTION}
found = [(path.relative_to(ROOT).as_posix(), marker)
         for path, text in sources.items()
         for marker in DECODER_MARKERS if re.search(marker, text)]

# Evidence must exist and be complete before any decoder marker may appear.  Each required field is a line that
# must carry a value; the evidence file itself is only a template until a controlled target run fills it.
REQUIRED_FIELDS = (
    "Build:", "Binary sha256:", "Vtable slot map:", "Class sizes:", "Selector table:",
    "CommandStreamInfo offsets:", "Representative command buffer:", "Target run:",
)
evidence_text = EVIDENCE.read_text() if EVIDENCE.exists() else ""
evidence_status = re.search(r"^Status:[ \t]*(\S+)", evidence_text, re.M)
evidence_proven = bool(evidence_status) and evidence_status.group(1) == "proven"
filled = {field: bool(re.search(r"^" + re.escape(field) + r"[ \t]*\S", evidence_text, re.M))
          for field in REQUIRED_FIELDS}

if found:
    assert evidence_proven and all(filled.values()), (
        "decoder/client submit markers present without exact ABI evidence: " + repr(found))

# Current tree: no decoder marker, evidence is not proven, and no field is filled.
assert found == [], found
assert evidence_status is not None and evidence_status.group(1) == "blocked", evidence_status
assert not any(filled.values()), filled

# Unknown selectors stay family-owned; nothing in the production set registers an external method of our own.
assert not any(re.search(r"\bIOExternalMethod\b|\bgetTargetAndMethodForIndex\b", text)
               for text in sources.values())

# The blocker report must name the gate it is bound to.
report_text = REPORT.read_text()
assert "scripts/tests/accel_abi_gate_test.py" in report_text
assert "Status: blocked" in report_text

print("PASS: IOAccel ABI gate: no decoder/client-submit marker, evidence status=blocked, no unverified field filled")
