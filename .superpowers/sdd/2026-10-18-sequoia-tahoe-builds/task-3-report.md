# Task 3 report: target packaging

## Scope

Implemented target-specific packaging. `scripts/package.sh` accepts `--target sequoia`, `--target tahoe`, or `--target all`; release packaging requires one selector. Selected bundles are staged as `target/Sequoia/Raphaeli.kext` and/or `target/Tahoe/Raphaeli.kext`; firmware and userspace remain shared at package root. Recovery installation selects the matching package bundle via `--target`, with `RAPHAELI_KEXT` preserved as an explicit override.

Generated `INSTALL.md` now documents explicit EFI target selection and `--system-root` for mounted target volumes. It does not recommend host-version detection.

## Tests

- `bash -n scripts/package.sh scripts/tests/package_target_test.sh`
- `./scripts/tests/package_target_test.sh`
- `python3 -m unittest scripts/tests/oc_install_target_test.py`

Fixture covers selected Sequoia, selected Tahoe, combined `all`, shared firmware/userspace, and exclusion of the unselected kext.

## Notes

Native macOS `.pkg` flow was not changed; it remains userspace/firmware packaging via `scripts/make-pkg.sh`. Existing unrelated worktree changes were not touched.
