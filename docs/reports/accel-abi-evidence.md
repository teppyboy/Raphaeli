# IOAccel command-stream ABI evidence

Status: blocked

Gate: `scripts/tests/accel_abi_gate_test.py` (contract in [accel-abi-gate.md](accel-abi-gate.md)).

This file is a template. No field below is filled. Nothing here is a guessed selector, offset,
token format, or packet subset. A field gets a value only from a controlled target run on the exact
build, recorded with its source. Until every field is filled and the status is changed to `proven`,
the gate forbids any decoder or client-submit marker in production sources.

## Why the evidence is blocked

- Decision A (accel-protocol.md §4): the submit wire-in is deferred. The next lane must decode
  `IOAccelCommandStreamInfo` and the AMD token path before `nmx_xnu_accel_ring_submit` is wired.
- The decoder needs the IB/VM path first (accel-gpu-submit.md "Why the submit cannot be wired honestly
  now", items 1–3; accel-vm-gate.md "Required bridge contract"). The VM bind and the mapping-record
  checks are not live.
- The Tahoe audit (tahoe-26.6-abi-audit.md) compares only export names and vtable slot order of the two
  standalone binaries. It does not prove class storage sizes, private ivar offsets, or method semantics.
  Its "Still unverified" list covers the exact target build (25G72 not confirmed), the WindowServer
  handshake, GPU VM, submission, and acceleration.
- No Phoenix hardware is available on the dev host. Selftest `raphaeli-accel-test=1` is hardware-gated
  (accel-protocol.md §5; accel-fence-timeout.md "Target selftest remains unverified").
- So no decoder is implemented: the token/selector/offset facts a decoder needs have not been obtained
  from a controlled run, and the gate in `scripts/tests/accel_abi_gate_test.py` keeps the decoder marker set
  empty until they are.

## Sequoia 15.7.8 (24G824, IOAcceleratorFamily2 v485)

Build:
Binary sha256:
Vtable slot map:
Class sizes:
Selector table:
CommandStreamInfo offsets:
Representative command buffer:
Target run:

Packet subset (gfx NOP/PACKET3 subset): not recorded.

## Tahoe 26.6 (25G72, IOAcceleratorFamily2 v487.4.3)

Build:
Binary sha256:
Vtable slot map:
Class sizes:
Selector table:
CommandStreamInfo offsets:
Representative command buffer:
Target run:

Packet subset (gfx NOP/PACKET3 subset): not recorded.

## Existing evidence this file cites (not ABI fields)

- Sequoia/Tahoe export and vtable-name comparison only: [tahoe-26.6-abi-audit.md](tahoe-26.6-abi-audit.md).
- Family selectors observed for the device/resource/queue planes (not a command-stream ABI): [accel-protocol.md](accel-protocol.md) §1–§2.
- Submit blockers and decision A: [accel-gpu-submit.md](accel-gpu-submit.md), [accel-protocol.md](accel-protocol.md) §4.
- VM contract still unimplemented: [accel-vm-gate.md](accel-vm-gate.md).
