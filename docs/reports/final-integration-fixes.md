# Final integration fixes

Date: 2026-10-18

## Recovery package layout

`recovery-install.sh` now resolves the packaged firmware census from
`tools/fw/stage.sh` and resolves target bundles from `target/Sequoia` or
`target/Tahoe` after `--target` parsing. `RAPHAELI_KEXT` remains an explicit
source override. Repository builds retain the `out/` fallback; packaged
installs without a target are rejected instead of selecting an ambiguous
legacy bundle.

## OpenCore bounds

`oc-install.py --add` always resolves a target from `--target` or
`--system-root`, including when `--kext-src` is used. The removed implicit
`TargetInfo('', '23.4.0', '')` path could inject an unbounded legacy entry;
selected entries now use Darwin 24.x or 25.x bounds.

## MacKernelSDK

Compiler wrappers source `scripts/kernel-sdk.sh`. `MAC_KERNEL_SDK` overrides
the SDK root; otherwise `research/MacKernelSDK` is selected when present.
Headers and pinned kmod library directories are used for kernel compilation and
linking. Missing SDK roots emit an explicit warning before falling back to the
active `xcrun --sdk macosx` SDK.

The Sequoia research checkout was copied into this worktree from the parent
research tree: `research/MacKernelSDK`, `research/nvidia-macos-driver`, and
`research/accel`. These remain ignored research inputs. No Tahoe forwarding
header was fabricated; Tahoe preflight remains blocked on the exact generated
header.

## Validation

- `bash -n` on changed shell wrappers and tests: passed.
- `python3 -m py_compile scripts/oc-install.py`: passed.
- `scripts/tests/mac_kernel_sdk_test.sh`: passed.
- `scripts/oc-install.test.sh`: passed.
- `scripts/recovery-install.test.sh`: passed (71 checks).
