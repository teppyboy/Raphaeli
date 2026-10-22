# Deployment readiness

## Verdict

Not ready to deploy as an accelerated end-user driver. Host build/package and
injection experiments pass, but client IOAccel work and target-hardware behavior
are not established. Do not treat this tree as a working accelerated
(Metal/Vulkan/IOAccel) driver.

## Verified (this audit)

- Host test suites listed below passed, including 8 OpenCore staging fixtures.
- Firmware census passed against the staged gfx1103 firmware set.
- Complete Sequoia dev-host build: 900/900 AMD sources, 81/81 runtime sources,
  link success, and `kmutil inspect -V tb` exit 0. Repeated after the latest
  source-state edits; same kext SHA-256 was emitted by the build.
- Package pipeline produced and integrity-checked ZIP and `.pkg` artifacts;
  `.pkg` payload inspection confirms userspace/firmware packaging scope only.
- Exact Tahoe 26.6.2 / Recovery 25G83 dependency injection was reproduced with
  OpenCore userspace tooling, and the controlled ordered staging/config test
  passed. This is not a target-machine boot test.
- The Sequoia task-free disassembly confirms the base free function performs
  family mapping cleanup before its super free chain. `RaphaeliTask::free()`
  would precede that cleanup; no safe post-map whole-VM destroy hook is proven.
  VM create/map/unmap/client submit therefore remain fail-closed.

## Unverified / not established

- Client IOAccel mapping, command decoding, and VM-aware job submission remain
  fail-closed (`-ENOTSUP`); no client GPU rendering is established.
- Dev host hardware remains Radeon Pro WX 5100 (`0x67c7`). User-provided Linux
  report is from a separate real Radeon 780M system, PCI `1002:1900` revision
  `b4` (HawkPoint1 / RADV Phoenix) with Linux amdgpu, RADV Vulkan enumeration,
  and accelerated radeonsi OpenGL. This is useful target bring-up evidence but
  not a macOS test. The ID differs from the project's presumed `0x15bf`; the
  target's IP discovery and active firmware identities are not present in the
  report, so `1002:1900` remains unvalidated by the macOS driver/firmware path.
  Target
  macOS attach, RADV discovery, rendering/readback,
  WindowServer/Metal, and RecoveryOS behavior have not been tested.
- The specific user's target EFI/config and Tahoe recovery boot remain
  unvalidated. The KDK/Recovery prelink experiment does not prove XNU loading,
  cross-KC runtime safety, panel operation, or successful reboot behavior.

## Blocking items before acceleration/readiness claims

1. Obtain Radeon 780M hardware and validate attach/boot across the supported
   exact OS/KDK builds, including RecoveryOS and the Tahoe injection strategy.
  Reconcile the Linux-reported `1002:1900` HawkPoint ID against the existing
  firmware/IP-discovery census before changing any PCI match.
2. Prove IOAccel task/VM/PASID/XCP ownership and teardown, BO mapping, verified
   command decode, VM-aware jobs/fences, and successful client rendering/readback.
3. Implement and validate a real Metal integration/plugin path; current shim
   intentionally reports unsupported.
4. Keep per-release dependency inputs pinned or explicitly refreshed, then run
   the firmware-backed build/package and exact-build injection gates.

## Residual risks

- Working tree has many uncommitted changes, so the audit results may not match
  a clean checkout.
- Shell and Python tests passing does not prove kernel-side correctness.
- Acceleration and end-user readiness remain unproven; do not call the driver
  ready until target hardware and client rendering gates pass.
