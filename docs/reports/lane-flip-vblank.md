# Flip/vblank lane report

## Contract

The display bridge now treats a plane update as accepted only after a bounded post-update
status read reports the requested scanout address. The poll runs inside
`nmx_dm_bridge_set_mode` while the existing `dc_lock` is held: 50 attempts at 1 ms,
for a 50 ms maximum. A missing status, missing plane, or address mismatch returns
`-ETIMEDOUT` and logs the expected and observed addresses. `RaphaeliFB` therefore
logs the mode refusal and does not advance its mode bookkeeping.

The framebuffer VBL remains the existing `thread_call` timer. No public flip API,
Tahoe ABI change, or hardware claim was added.

## Changed files

- `Raphaeli/Override/src/nmx_dm_bridge.c`
- `docs/reports/lane-flip-vblank.md`

## Validation

- `git diff --check`: passed.
- `./scripts/cclk.sh Raphaeli/Override/src/nmx_dm_bridge.c`: not run to completion;
  the checkout has no `research/MacKernelSDK`, and the command also requires the
  generated `lkobj` directory.
- Hardware vblank/flip behavior: unverified, as required for this lane.

## Residual risk

The bounded poll uses `DELAY` while holding the display-manager lock. It is deliberately
bounded to avoid an unbounded wait; actual hardware timing still needs validation on a
Phoenix target.
