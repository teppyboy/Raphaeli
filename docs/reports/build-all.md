# Unified Sequoia/Tahoe build wrapper

## Scope

- Added `scripts/build-all.sh [all|sequoia|tahoe]` (default `all`).
- Kept `./scripts/build.sh && ./scripts/package.sh` as the single-target path.
  `build.sh` gained `RAPHAELI_OUT` (default `out-disp`); it accepts only
  `out-disp` or `out/target/<target>` so other link destinations are refused.
- No compiler logic duplicated: `build-all.sh` calls `build.sh`, `link.sh`, and
  `check-oc-injection.sh`.
- Prior commit `2be337c` is not present in this checkout or any local ref; the
  design is taken from this request and the existing `check-oc-injection.sh` gate.

## Behavior

- Output isolation: `out/target/Sequoia/Raphaeli.kext` and
  `out/target/Tahoe/Raphaeli.kext`. Stale bundles are removed before a run.
- `all` compiles once through `build.sh` (Sequoia output), then relinks the same
  objects into the Tahoe bundle with `link.sh`.
- Firmware: explicit `RAPHAELI_FW_SRC` only, validated by `stage.sh` (same as
  `build.sh`).
- Tahoe gate (fail closed): requires `RAPHAELI_OC_KEXTINJECT`,
  `RAPHAELI_TAHOE_KC`, and `RAPHAELI_TAHOE_KDK_EXT` containing
  `IOGraphicsFamily.kext` and `IOAcceleratorFamily2.kext` binaries/plists. All
  are checked before the source build. After linking, `check-oc-injection.sh`
  injects the KDK dependencies before Raphaeli; any failure deletes
  `out/target/Tahoe/` and exits 1.
- Nothing is searched for on the host.

## Validation

- `bash -n scripts/build-all.sh scripts/build.sh scripts/build-all.test.sh` passed
  (bash 3.2.57 on this host).
- `bash scripts/build-all.test.sh`: 6/6 passed. Covers unknown target, missing
  firmware, missing KextInject / Tahoe KC / KDK deps (including partial KDK), all
  failing before any compile.
- `git diff --check` passed.
- Not run: full build (needs real `linux-firmware/amdgpu` and a compile of 900
  sources), Tahoe gate (no extracted Tahoe Recovery `BootKernelExtensions.kc` on
  this host; the KDK 25G83 dependency pair exists under `/tmp`). Both remain
  unverified here. Recovery KC extraction is still open.

## Risks

- The Tahoe gate proves OpenCore prelink injection only; it does not prove
  runtime load, attach, or WindowServer behavior (hardware-gated).
- `all` relinks the Tahoe bundle from the shared objects; any target-specific
  divergence would need a separate design.
