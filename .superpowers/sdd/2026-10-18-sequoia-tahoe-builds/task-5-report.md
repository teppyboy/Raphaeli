# Task 5: Full verification report

Date: 2026-10-18
Branch: `sequoia-tahoe-builds`
HEAD: `c06eda2 fix: harden target build and link paths`

## Scope

Verification only. No production code modified. Packaging/archive inspection attempted only when inputs existed.

## Step 1: Required host tests

### Command

```sh
./scripts/oc-install.test.sh
```

### Result

PASS. Output ended with:

```text
ALL TESTS PASSED
```

### Command

```sh
python3 -m unittest scripts/tests/oc_stage_graphics_test.py scripts/tests/oc_install_target_test.py
```

### Result

PASS. `Ran 20 tests ... OK`.

### Command

```sh
./scripts/tests/package_target_test.sh
```

### Result

PASS. Output ended with:

```text
passed=1 failed=0
```

The fixture covered `sequoia`, `tahoe`, and `all`; `all` contained both target bundles, while single-target archives excluded the other bundle.

## Additional verification

### Target argument/build routing

```sh
./scripts/tests/target_build_args_test.sh
```

PASS: `passed=1 failed=0`.

### Bash syntax

```sh
find . -type f \( -name '*.sh' -o -name '*.bash' \) -not -path './.git/*' -not -path './deps/*' -not -path './kpi/*' -print0 | xargs -0 -n1 bash -n
```

PASS. 33 shell files checked; no diagnostics.

### Diff whitespace

```sh
git diff --check
```

PASS; no whitespace errors.

### Full available shell test sweep

```sh
for t in scripts/*.test.sh scripts/tests/*.test.sh; do [ -f "$t" ] || continue; bash "$t"; done
```

Results:

- PASS: `scripts/check-oc-injection.test.sh`
- PASS: `scripts/collect-recovery.test.sh`
- FAIL: `scripts/fw-bundle.test.sh` — required `firmware/amdgpu/*.bin` absent; `out-disp/Raphaeli.kext` absent.
- FAIL: `scripts/install.test.sh` — fixture expects `out/Raphaeli.kext` and firmware inputs, both absent in this checkout; 5 passed, 11 failed.
- PASS: `scripts/oc-install.test.sh`
- PASS: `scripts/recovery-install.test.sh` — `passed=71 failed=0`.

The two failures are unavailable build-input gates, not source-test assertion regressions.

### Python test discovery

```sh
python3 -m unittest discover -s scripts/tests -p '*_test.py'
```

PASS. 20 tests; `OK`.

## Step 2: Target build counts and Mach-O outputs

### Sequoia build

```sh
./scripts/build.sh --target sequoia
```

PASS: `sequoia sources: 900  compiled: 900  failed: 0`.

```sh
./scripts/rt.sh --target sequoia
```

FAIL: `sequoia runtime sources: 81  failed: 2`.

Both failures are accelerator translation units because the reconstructed Sequoia private header is absent:

```text
fatal error: '../../research/nvidia-macos-driver/kexts/NVRM/accel/re/IOGraphicsAccelerator2.h' file not found
```

No linked Sequoia kext exists, so the x86_64 Mach-O output gate is unresolved.

### Tahoe build

```sh
./scripts/build.sh --target tahoe
```

NOT RUN beyond preflight; rejected before compilation:

```text
build.sh: refusing tahoe before compiling; missing matching Tahoe ABI header .../research/tahoe-forwarding/nmx_accel_tahoe_forwarding.h
```

```sh
./scripts/rt.sh --target tahoe
```

NOT RUN beyond preflight; same missing matching Tahoe ABI header rejection.

Tahoe source count and x86_64 Mach-O output are unavailable by design until matching private ABI declarations are supplied. `--target all` is likewise expected to reject before partial work.

### Current output inventory

- Sequoia object root exists, but only partial runtime objects remain after the failed runtime build.
- Tahoe object root absent.
- `out/target/Sequoia/Raphaeli.kext/Contents/MacOS/Raphaeli` absent.
- `out/target/Tahoe/Raphaeli.kext/Contents/MacOS/Raphaeli` absent.
- `out-disp/Raphaeli.kext/Contents/MacOS/Raphaeli` absent.
- `firmware/amdgpu/` contains no staged firmware files.

Therefore no target currently satisfies the complete-source-count plus x86_64 Mach-O output requirement.

## Step 3: Package/archive inspection

### Commands

```sh
unzip -l dist/Raphaeli-*-x86_64.zip
pkgutil --payload-files dist/Raphaeli-*-x86_64.pkg
```

### Results

Both commands were attempted. No `dist/` directory or matching archive/package exists:

```text
unzip: cannot find or open dist/Raphaeli-*-x86_64.zip
Could not open package to list files: dist/Raphaeli-*-x86_64.pkg
```

Package tree inspection is unresolved because linking, userspace outputs, and firmware staging did not produce release inputs. The fixture-level package inspection passed for all selectors, including the `all` two-bundle layout.

## Step 4: Unresolved gates

### Exact-KC OpenCore prelink

No current-branch kext was available for a fresh real prelink run. Existing exact-build evidence in `docs/reports/tahoe-recovery-exact-image.md` records:

- Tahoe Recovery build `25G83` / ProductVersion `26.6.2`: Raphaeli alone FAILS with missing graphics-family superclass vtables and `Invalid Parameter`.
- The exact-build KDK `25G83` IOGraphicsFamily and IOAcceleratorFamily2 staged before Raphaeli: all three per-kext injections PASS.
- This is injection/prelink evidence only; it does not establish a successful target boot.

Existing Sequoia evidence in `docs/reports/oc-vtable-reproduction.md` similarly records Raphaeli-alone failure and matching graphics-family dependency injection success. These runs used prior available binaries, not a newly linked artifact from this checkout.

### Hardware gates

Unverified: target Phoenix boot, Recovery attachment, display/panel light-up, GPU reset, firmware load, ring/fence operation, WindowServer operation, Vulkan, and panic/reboot behavior. Hardware is unavailable on the development host.

## Final status

Required focused host tests pass. Static shell/argument/diff checks pass. Full target verification is blocked by missing Sequoia reconstructed private headers, missing Tahoe forwarding ABI header, missing firmware, and absent linked bundles/packages. No production code was changed.
