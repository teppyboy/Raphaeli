# Raphaeli AMD kext base

This directory is a private local copy of the AMD/Intel `gpu-port/xkpi/` at the revision recorded in `../vendor/SOURCES.md`. Keep this port's source provenance and notices with the code.

## Local source layout

Set `GPU_SRC_ROOT` to a directory containing:

```text
$GPU_SRC_ROOT/
  xkpi/       # this directory
  kpi/
    drm-kmod/ # freebsd/drm-kmod; recorded pin in ../vendor/SOURCES.md
    freebsd-src/ # LinuxKPI and CK from FreeBSD; recorded pin in ../vendor/SOURCES.md
```

The enclosing project directory is `Raphaeli`; the kext is named `Raphaeli` (bundle `Raphaeli.kext`, class `Raphaeli`, id `me.tretrauit.raphaeli`); its first target is the AMD Radeon 780M (Phoenix, 0x15bf, gfx1103). The first bring-up target is AMDGPU only. i915, xe, NPU targets are out of scope. `amd.flags` is generated from the pinned drm-kmod Makefiles:

```sh
python3 gen_flags.py "$GPU_SRC_ROOT/kpi/drm-kmod" amd.flags
./build.sh                            # 900 kernel sources -> obj/
GPU_SRC_ROOT="$GPU_SRC_ROOT" ./rt.sh  # 74 runtime sources -> lkobj/, srcobj/, xnuobj/
./link.sh out                         # link -> out/Raphaeli.kext (x86_64, macOS 15+)
```

All three stages complete on this tree: 900/900 sources compile, 74/74 runtime sources compile,
`link.sh` produces `out/Raphaeli.kext` (Mach-O kext bundle, ~10.9 MB; only kernel-provided
IOKit/libkern symbols remain undefined).

The source tree derives from FreeBSD LinuxKPI/drm-kmod and includes multiple licenses. Before distribution, audit exact compiled files, their SPDX identifiers, all dependencies, and applicable source-offer obligations. Never distribute firmware without verifying its license and checksum.

## Current state

- `Raphaeli.kext` is the Raphaeli AMD driver port prototype (Radeon 780M first target), not a minimal device-matching stub.
- Build scripts still need consistent portable root handling before the commands above work reliably; the original scripts target the author's mounted `/Volumes/MiniData/build/gpu-src` tree. This local copy is a work in progress. (`build.sh`/`rt.sh`/`link.sh` now default to the enclosing tree via `GPU_SRC_ROOT`.)
- The prototype has not been loaded on hardware according to `../REFERENCE-gpu-port.md`.
- Do not install or load it in the current macOS VM; the VM exposes only Reims vGPU (`106b:eeee`).
