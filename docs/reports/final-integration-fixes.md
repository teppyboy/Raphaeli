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

Compiler wrappers source `scripts/kernel-sdk.sh`. The default
`research/MacKernelSDK` checkout and any `MAC_KERNEL_SDK` override must resolve
to pinned commit `3f750085caa17ec3a7880f11c11bf4f48cd6a164`, with its Headers
and kmod library directories present. Missing, non-Git, or different revisions
fail closed; the active `xcrun --sdk macosx` SDK is never used as a fallback.

The Sequoia research checkout was copied into this worktree from the parent
research tree: `research/MacKernelSDK`, `research/nvidia-macos-driver`, and
`research/accel`. These remain ignored research inputs. No Tahoe forwarding
header was fabricated; Tahoe preflight remains blocked on the exact generated
header.

## Validation

- `bash -n` on changed shell wrappers and tests: passed.
- `python3 -m py_compile scripts/oc-install.py`: passed.
- `scripts/tests/mac_kernel_sdk_test.sh`: passed; all six compiler wrappers plus `kext-build.sh` and `link.sh` are checked for selected SDK include/library use, exact SDK commit pinning, fail-closed missing/invalid overrides, and all Sequoia accelerator headers.
- `scripts/oc-install.test.sh`: passed, including explicit `--kext-src` rejection without `--target`/`--system-root`.
- `scripts/recovery-install.test.sh`: passed (74 checks), including packaged `tools/fw/stage.sh` resolution/failure and target bundle selection.
- `./scripts/build.sh --target sequoia`: passed (`900/900`, failed `0`).
- `./scripts/rt.sh --target sequoia`: passed (`81`, failed `0`).
- Tahoe build/runtime/link remain intentionally blocked until exact 26.6.2/25G83 ABI validation.
