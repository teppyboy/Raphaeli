# Build and package report

## Build and source gates

`RAPHAELI_FW_SRC="$PWD/firmware/amdgpu" ./scripts/build.sh` completed on the
Sequoia dev host after the latest `nmx_accel_bridge.c` safety-comment edit.
The build reported 900/900 AMD sources, 81/81 runtime sources, linked
`out-disp/Raphaeli.kext`, and `kmutil inspect -V tb -p "$PWD/out-disp/Raphaeli.kext"`
returned 0. The kext binary SHA-256 is
`354fddfd7a26604c59d8d11394a9755f1b9de5ba15d47d9d4a61b066de213af1`
(14,302,136 bytes).

## Package validation

`./scripts/package.sh` produced the x86_64 ZIP and `.pkg`. ZIP integrity passed.
`pkgutil --payload-files` confirmed the `.pkg` contains only RADV/libdrm
userspace dylibs and the ICD manifest; it does not install the kext or firmware.
No installer was run. Artifact hashes were recorded in the build log rather than
this report because the report itself is included in package inputs.

## Limits

This is build/package validation only. The host Radeon is a Pro WX 5100
(`0x67c7`), not the target Radeon 780M (`0x15bf`); attach, RADV operation,
rendering, WindowServer/Metal, Tahoe runtime, and RecoveryOS behavior remain
unverified. Client submission and per-task VM operations remain fail-closed.
