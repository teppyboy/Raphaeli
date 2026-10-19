# Refusal diagnostics lane

## Scope

The display-engine bridge now records every refusal stage in
`Raphaeli/Override/src/nmx_dm_bridge.c`. This lane does not change the Tahoe ABI,
DC behavior, or the public bridge boundary.

## Implementation

- Replaced the partial edit's unsupported `__ATOMIC_AXED`/compiler builtin usage with
  the project FreeBSD-compatible `atomic_fetchadd_int` API from `machine/atomic.h`.
- Replaced bridge logging with project kernel C logging through `device_printf`.
- Added monotonic refusal counters and stage names for mode input, device,
  connector, stream detach/create, validation, commit, plane creation, and plane
  update.
- Routed all bridge failure exits through stage accounting. Detach failures are
  accounted inside `detach_stream`; the caller preserves the returned errno.
- Added `scripts/tests/refusal_diagnostics_test.sh`, a focused SDK-independent
  static check for logging, atomic, stage, and error-path coverage.

## Validation

Passed:

- `scripts/tests/refusal_diagnostics_test.sh`
- `git diff --check`

Attempted:

- `./scripts/rt.sh --target sequoia` — blocked before compilation because the
  checkout lacks `research/MacKernelSDK`; all 49 source invocations consequently
  report the same missing-SDK error.
- `./scripts/build.sh --target sequoia` — timed out after 120 seconds while
  initializing/cloning the pinned Mesa submodule; no source result obtained.

Hardware validation remains unavailable on the development host. Tahoe was not
run or modified.

## Residual risks

The bridge and full runtime/build compile remain unverified until the pinned
MacKernelSDK is present and dependency initialization completes. The static
check verifies source wiring only; it cannot exercise DC failure paths.
