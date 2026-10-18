# Task 3 report: target packaging

## Scope

Implemented packaging selector/layout only. `scripts/package.sh` accepts `--target sequoia`, `--target tahoe`, `--target all`. Selected bundles are staged as `target/Sequoia/Raphaeli.kext` and/or `target/Tahoe/Raphaeli.kext`; firmware and userspace remain shared at package root. Existing positional version invocation remains supported when no selector is used.

Generated `INSTALL.md` now documents explicit EFI target selection and `--system-root` for mounted target volumes. It does not recommend host-version detection.

## Tests

- `bash -n scripts/package.sh scripts/tests/package_target_test.sh`
- `./scripts/tests/package_target_test.sh`
- `python3 -m unittest scripts/tests/oc_install_target_test.py`

Fixture covers selected Sequoia, selected Tahoe, combined `all`, shared firmware/userspace, and exclusion of the unselected kext.

## Notes

Native macOS `.pkg` flow was not changed; it remains userspace/firmware packaging via `scripts/make-pkg.sh`. Existing unrelated worktree changes were not touched.
