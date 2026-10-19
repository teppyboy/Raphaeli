# Task 2 report — target metadata and OC staging behavior

## Scope

Implemented Task 2 only. Existing Task 1 target resolution remains the source of selected bundle paths and Darwin kernel bounds. This change adds target-aware status reporting and regression coverage for single-bundle removal.

## Behavior

- `--add --target sequoia|tahoe` continues to refresh an existing `Raphaeli.kext` entry in place with the selected `MinKernel` and `MaxKernel`, without adding a duplicate entry or rewriting unrelated fields.
- `--status --target <target>` reports the selected target and its bounds.
- `--status` without an explicit selector infers Sequoia/Tahoe from the existing `Kernel>Add` bounds; unknown or absent bounds are reported as `unknown`/`not selected`.
- `--remove` removes only the `Kernel>Add` entry identified by `BundlePath=Raphaeli.kext` and the staged `EFI/OC/Kexts/Raphaeli.kext` directory. Other staged kexts and config entries remain.
- Bundle naming remains unchanged: the staged bundle path is `Raphaeli.kext`, and target bundle metadata retains `CFBundleName=Raphaeli` when supplied by the selected bundle.

## Tests

Added target-aware fixtures for explicit status target/bounds, bounds-based status inference, and removal isolation. Existing Task 1 refresh coverage remains in place.

Commands passed:

```sh
python3 -m unittest scripts/tests/oc_install_target_test.py
./scripts/oc-install.test.sh
python3 -m py_compile scripts/oc-install.py scripts/tests/oc_install_target_test.py
git diff --check
```

Results: 10 Python tests passed; all shell integration checks passed; compilation and diff checks passed.

## Files

- `scripts/oc-install.py`
- `scripts/tests/oc_install_target_test.py`
- `.superpowers/sdd/2026-10-18-sequoia-tahoe-builds/task-2-report.md`

Pre-existing unrelated worktree changes were not modified or staged.

## Concerns

- Hardware, OpenCore runtime behavior, and target-kernel prelink compatibility remain unverified on this host.
- Status target inference depends on exact configured bounds; an entry with nonstandard bounds is intentionally reported as `unknown`.
