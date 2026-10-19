# Task 3 fix round 1: target packaging

## Scope

Release packaging now requires `--target sequoia|tahoe|all`. Generated `INSTALL.md` is layout-specific: selected releases document only their target bundle; `all` documents both explicit target commands and paths. Legacy no-target packaging is rejected to prevent an ambiguous kext layout.

## Tests

- `bash -n scripts/package.sh scripts/tests/package_target_test.sh`
- `bash scripts/tests/package_target_test.sh`
- `bash scripts/oc-install.test.sh`

The packaging fixture covers version plus `--target`, `--target=`, case normalization, missing value, empty value, missing selector, duplicate selector, invalid selector, `INSTALL.md` presence/content, source markers, selected layouts, and unselected-layout exclusion.

## Notes

Native macOS `.pkg` flow remains unchanged. Existing unrelated worktree changes were not touched.
