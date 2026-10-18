# Sequoia/Tahoe build verification

Date: 2026-10-19

## Verification status

Sequoia is the only verified target in this checkout. Tahoe builds remain
intentionally blocked until the exact macOS 26.6.2 / Darwin build 25G83 private
accelerator ABI is validated. The pinned forwarding source is from macOS
26.7.1 and must not be treated as a validated 25G83 ABI. `SOURCE.lock` remains
`tahoe_target_validated=no`; build, runtime, and link preflight reject Tahoe.
No Tahoe build success, binary, or ABI claim is made here.

## Sequoia

- `./scripts/build.sh --target sequoia`: verified `900/900`, failed `0`.
- Target source preparation is hash-locked. Sequoia preparation generates the
  Tahoe forwarding artifact for the separate Tahoe lane; Sequoia does not
  consume that artifact.
- Tahoe source preparation and target-specific link paths were not used to
  claim Sequoia/Tahoe parity.

## Tahoe blocker

- Required validation target: macOS **26.6.2**, build **25G83**.
- Current forwarding provenance: macOS **26.7.1**.
- Exact 25G83 Recovery/KDK injection evidence covers dependency staging only;
  it does not validate the private accelerator forwarding ABI.
- `./scripts/build.sh --target tahoe`, `./scripts/rt.sh --target tahoe`, and
  `./scripts/link.sh --target tahoe` must remain fail-closed before artifacts.

## Remaining limits

Hardware boot, WindowServer open, panel light-up, GPU reset, ring execution,
firmware load, exact-KC runtime behavior, and Tahoe ABI validation remain
unverified. Do not set `tahoe_target_validated=yes` or fabricate ABI headers.
