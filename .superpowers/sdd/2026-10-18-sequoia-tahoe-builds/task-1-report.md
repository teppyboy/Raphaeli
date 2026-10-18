# Task 1 report — EFI target resolution

## Scope

Implemented Task 1 only. Existing `--system-root` parsing/staging flow remains intact. Added target selection to `scripts/oc-install.py` and focused resolver/integration tests.

## Behavior

- `--target sequoia` selects `target/Sequoia/Raphaeli.kext` with `MinKernel=24.0.0` and `MaxKernel=24.99.99`.
- `--target tahoe` selects `target/Tahoe/Raphaeli.kext` with `MinKernel=25.0.0` and `MaxKernel=25.99.99`.
- When no explicit target is supplied, `--system-root` is read at `System/Library/CoreServices/SystemVersion.plist`; ProductVersion `15.x` selects Sequoia and `26.x` selects Tahoe.
- Missing target/system root and unsupported ProductVersion values fail before config or EFI mutation.
- `--kext-src` remains a single-bundle override. Existing explicit override behavior remains available without target selection; when a target is supplied, target bounds are used.
- No host `sw_vers` invocation was added.

## Tests

Added `scripts/tests/oc_install_target_test.py` covering explicit target paths/bounds, system-root ProductVersion mapping, unsupported/missing selection with no mutation, selected bundle staging, and explicit kext override.

Commands passed:

```sh
python3 -m unittest scripts/tests/oc_install_target_test.py
./scripts/oc-install.test.sh
python3 -m py_compile scripts/oc-install.py scripts/tests/oc_install_target_test.py
git diff --check
```

Existing dirty files outside Task 1 were not modified by this work. The commit also contains pre-existing parent-owned changes in `.gitignore`, `docs/reports/oc-vtable-reproduction.md`, `docs/reports/tahoe-recovery-exact-image.md`, `scripts/oc-stage-graphics.py`, and `scripts/tests/oc_stage_graphics_test.py`; these were already staged in the worktree and were intentionally left intact.

## Round 1 fixes

- Existing `Kernel>Add` entries now always refresh selected `MinKernel` and `MaxKernel`; bound updates no longer depend on a `Comment` change.
- Added an integration fixture that runs the installer from a package-shaped tree with `--target tahoe` and no `--kext-src`, asserting the staged bundle is Tahoe.
- Added regression coverage for refreshing bounds on an already matching entry.

Commands passed:

```sh
python3 -m unittest scripts/tests/oc_install_target_test.py
./scripts/oc-install.test.sh
python3 -m py_compile scripts/oc-install.py scripts/tests/oc_install_target_test.py
 git diff --check
```
