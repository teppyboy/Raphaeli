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

Existing dirty files outside Task 1 were not modified or staged.
