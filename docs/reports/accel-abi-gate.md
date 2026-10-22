# IOAccel ABI gate (static, fail-closed)

Status: blocked

Gate test: `scripts/tests/accel_abi_gate_test.py`
Evidence file: [accel-abi-evidence.md](accel-abi-evidence.md) (currently `Status: blocked`, no field filled)

## What the gate checks

The test is a host-only static check. It reads source text; it does not load a kext, call IOAccel, or
run any GPU work. It proves only that the source tree matches the evidence state. It says nothing about
IOAccel runtime semantics.

1. **Decoder markers absent.** The production set is `Kernel/nmx_accel.cpp`, `Kernel/nmx_accel.h`,
   `Kernel/nmx_accel_uc.cpp`, `Kernel/nmx_kext.cpp`, and `Override/src/nmx_accel_bridge.c`. None may contain
   a decoder or client-submit marker: `processDataBuffers`, `beginCommandStream`, `endCommandStream`,
   `bindResource(`, `IOAccelCommandStreamInfo`, `submit_command_buffers`, `raphaeli-accel-client-test`,
   or `nmx_accel_decode`.
2. **Evidence gates any marker.** If a marker appears, the test passes only when the evidence file says
   `Status: proven` and all eight required fields carry a value: `Build:`, `Binary sha256:`,
   `Vtable slot map:`, `Class sizes:`, `Selector table:`, `CommandStreamInfo offsets:`,
   `Representative command buffer:`, and `Target run:`.
3. **Current tree is blocked.** With no marker present, the evidence must read `Status: blocked` and no
   required field may be filled. Any filled field fails the test, so an unverified ABI value cannot slip in.
4. **No external method of our own.** The production set may not use `IOExternalMethod` or
   `getTargetAndMethodForIndex`. Unknown selectors stay owned by IOAcceleratorFamily2 and return
   `kIOReturnUnsupported`.
5. **Self-binding.** This report must name the gate test path and contain `Status: blocked`.

## Fail-closed contract

- Unknown IOAccel selectors return `kIOReturnUnsupported`. No selector is registered for a client submit.
- No decoder is implemented. Guessing selectors, offsets, token formats, or a packet subset is forbidden
  (accel-protocol.md §4; accel-gpu-submit.md item 2).
- A client submit reaches the family's VA-map step and is refused there (`commitIntoGPUPageTable` returns
  false). It cannot reach `nmx_xnu_accel_ring_submit`.
- The VM and submit contracts stay fail-closed until their own gates exist: accel-vm-gate.md (task VM and
  raw-submit gate), and the lifecycle, mapping, and submit tests under `scripts/tests/accel_vm_*_test.py`.
- The boot-arg selftest `raphaeli-accel-test=1` remains the only submit path and is hardware-gated.

## Lifting the block

The gate may move to `Status: proven` only after all of the following. Each is a separate lane:

1. A controlled target run on the exact build fills every field in accel-abi-evidence.md, with the binary
   sha256 and the source of each value.
2. The task VM bridge and the mapping-record checks in accel-vm-gate.md are implemented and tested.
3. The decoder (`IOAccelCommandStreamInfo` offsets and the gfx NOP/PACKET3 subset) is added, with unknown
   tokens returning `kIOReturnUnsupported`.
4. The gate test is updated in the same change that adds a marker, so the marker and evidence move together.

Until then this gate fails if a decoder or submit marker appears without proven evidence, and it passes
only in the current blocked state.

## Validation

Run from the repo root: `python3 scripts/tests/accel_abi_gate_test.py`, plus the lifecycle, mapping,
submit, gate, and fence tests (`accel_vm_lifecycle_test.py`, `accel_vm_mapping_test.py`,
`accel_vm_submit_test.py`, `accel_vm_gate_test.py`, `accel_fence_test.py`). Results are recorded in the
task output for this lane.
