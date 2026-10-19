# Task 3 fix round 2: recovery target selection

## Scope

`recovery-install.sh` now accepts `--target sequoia|tahoe` and resolves `target/Sequoia/Raphaeli.kext` or `target/Tahoe/Raphaeli.kext` from the package root. `RAPHAELI_KEXT` remains an explicit override. Generated `INSTALL.md` uses the matching recovery command. Package validation now rejects missing required userspace dylibs and firmware blobs.

## Tests

- `bash -n scripts/recovery-install.sh scripts/recovery-install.test.sh scripts/package.sh scripts/tests/package_target_test.sh`
- `bash scripts/recovery-install.test.sh` — 55 passed, 0 failed
- `bash scripts/tests/package_target_test.sh` — passed, 0 failed; archive executable marker content asserted
- `bash scripts/oc-install.test.sh` — all tests passed

Recovery fixture covers Sequoia/Tahoe bundle resolution, explicit override precedence, and missing userspace/firmware inputs. Packaging fixture covers archive marker content and required input failures.

## Round 3 test fixes

- Recovery fixture uses distinct Sequoia/Tahoe executable markers, runs each target with `--apply`, and verifies the installed marker.
- Recovery and package fixtures table-drive every required userspace dylib and firmware blob failure.

## Notes

No hardware validation. Existing unrelated worktree changes untouched.
