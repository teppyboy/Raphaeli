# Accelerator source provenance and target audit

Date: 2026-10-19

## Reproducible source inputs

`Raphaeli/Kernel/Accel/upstream/` is the tracked source snapshot used by the
accelerator lane. `SOURCE.lock` records the upstream repository, commit,
per-file SHA-256 hashes, and generated-header provenance. The commit is:

- Repository: `https://github.com/nullmoth/nvidia-macos-driver.git`
- Commit: `637282334617d27bccf8aa2448497c0f19465dc8`
- Source path: `kexts/NVRM/accel`

`scripts/prepare-accel-sources.py` verifies every locked file before preparing
a clean target include tree. It generates
`nmx_accel_tahoe_forwarding.h` by applying the fixed Raphaeli class-name map to
the pinned upstream `tahoe_fwd.h`; it does not read ignored `research/` files.
Repeated Sequoia preparation is byte-for-byte deterministic.

## Tahoe ABI boundary

The forwarding source's exact private ABI provenance is **macOS 26.7.1**.
The target evidence audited in this branch is **macOS 26.6.2, build 25G83**.
Those are not interchangeable claims. `SOURCE.lock` therefore records
`tahoe_target_validated=no`; build, runtime, and link preflight refuse Tahoe
before creating artifacts. No universal Tahoe support is claimed.

The 26.6.2/25G83 evidence remains the exact Recovery/KDK injection audit in
`tahoe-recovery-exact-image.md`. It validates dependency injection behavior,
not that the 26.7.1 private accelerator forwarding ABI is valid for 26.6.2.
A matching 26.6.2 private-header/vtable audit must update the lock metadata and
review the generated forwarding source before Tahoe builds are enabled.

## Sequoia gate

Sequoia uses the same tracked reconstructed accelerator declarations without
Tahoe forwarding. Its target source preparation is clean-checkout safe and
hash-verified. Hardware attach, WindowServer open, panel light-up, GPU reset,
ring execution, and final exact-KC runtime behavior remain unverified gates.
