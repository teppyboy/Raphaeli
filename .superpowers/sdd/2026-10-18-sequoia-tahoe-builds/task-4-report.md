# Task 4 report: target-aware compile/link path

## Scope

Implemented `--target sequoia|tahoe|all` for `scripts/build.sh`, `scripts/rt.sh`, and `scripts/link.sh`. Build outputs are isolated under `obj/target/Sequoia` and `obj/target/Tahoe`; linked bundles are isolated under `out/target/Sequoia` and `out/target/Tahoe`. Per-target logs prevent stale objects/logs crossing builds.

Compiler wrappers propagate `NMX_TARGET` and target object roots. Accelerator translation units receive `-DNM_TAHOE` only for Tahoe. `nmx_accel.h` rejects Tahoe compilation unless a generated `nmx_accel_tahoe_forwarding.h` is supplied through the ignored `research/tahoe-forwarding` include path; no private Tahoe ABI was fabricated or committed. Sequoia keeps the existing private ABI path without the Tahoe define.

## Tests

- `bash -n scripts/build.sh scripts/rt.sh scripts/link.sh scripts/cc.sh scripts/cclk.sh scripts/ccsrc.sh scripts/ccxx.sh scripts/one.sh scripts/tests/target_build_args_test.sh scripts/package.sh`
- `./scripts/tests/target_build_args_test.sh`
- `git diff --check`
- `scripts/build.sh --help`, `scripts/rt.sh --help`, `scripts/link.sh --help`

The static/mock test verifies selector support, isolated roots, Tahoe `-DNM_TAHOE`, and Sequoia omission of the define.

## Constraints / concerns

A real Tahoe accelerator build intentionally fails until matching private Tahoe forwarding headers are generated from the target SDK/KC. This prevents silently linking Sequoia private ABI against Tahoe. Hardware and full native builds were not run on this host.

Existing unrelated worktree changes were not touched.
