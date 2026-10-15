# Radeon 780M macOS graphics stack

Goal: bring up AMD Phoenix/RDNA3 APU graphics on x86_64 macOS with the same broad split as the AMD path in `research/nvidia-macos-driver/`: an `amdgpu`-based kernel/DRM port, Mesa RADV user-space Vulkan, then the AMD-capable Metal accelerator/plugin path using `metal2vulkan` where appropriate.

```text
Metal apps → Metal plugin → AIR-to-SPIR-V/runtime → RADV → libdrm/DRM node → AMDGPU XNU kext → Radeon 780M
```

The pieces are distinct: Mesa's RADV and `metal2vulkan` do not initialize the GPU or replace an AMD kernel driver. The AMD kext must provide working PCI/resource setup, AMD firmware loading, GPU memory/VM, scheduling/submission, interrupts, fences, and a user-visible DRM node. Display/IOKit handoff is another milestone.

## Repository layout

Domain-organized like NootedRed: the kext sources live in one directory, all build entry points in one, no build artifacts in git.

```text
Raphaeli/            the kext (bundle Raphaeli.kext, id me.tretrauit.raphaeli)
  Info.plist           personalities + module declaration
  Kernel/              IOKit-side C++ glue (nmx_kext, nmx_fb, nmx_accel, nmx_pci, nmx_platform, ...)
  Compat/              FreeBSD-on-XNU compatibility layer (src/ + include/)
  Override/            LinuxKPI/drm-kmod forks and replacements (src/, display/, i915/, xe/, linux/, include/)
  Firmware/            firmware staging (stage.sh + blob-name README)
  Attic/               parked NPU lane (kext-npu/, override-npu/, nmx_npu_kext.cpp, cc-npu*/all-npu*/fork_npu)
scripts/             every build/tooling script (single build entry)
  build.sh             900 drm-kmod AMD/DRM/TTM sources -> obj/        (900/900)
  rt.sh                77 runtime sources -> lkobj/, srcobj/, xnuobj/  (77/77; 78th was the parked NPU glue)
  link.sh              links Raphaeli.kext -> out/ from obj dirs
  all-i915.sh / all-xe.sh   Intel lanes (obj-i915/, obj-xe/ from kpi/drm-kmod and linux-6.14)
  cc.sh / cclk.sh / ccsrc.sh / ccxx.sh / cc-i915.sh / cc-xe.sh / one.sh   per-source compilers
  install.sh / oc-install.py / oc-install.sh   deployment (+ install.test.sh / oc-install.test.sh)
  package.sh           dist/ release zip
  gen_ccdb.sh / gen_flags.py / srclist.py / xesrc.py / fork_*.py   generators
  tests/               host-side selftests (nmx_fb_edid_test.cpp)
docs/                design notes + lane contracts (docs/reports/ = key audit reports)
patches/             mesa-macos.patch, libdrm-macos.patch
kpi/                 pinned reference trees (symlinks into research/): drm-kmod, freebsd-src
vendor/              source provenance (SOURCES.md)
probe/               hardware probe tool
out/, out-disp/, dist/, firmware/, work-*/, obj*/, lkobj/, srcobj/, xnuobj/, logs*/   gitignored build trees
```

The enclosing research trees under `research/` (drm-kmod, freebsd-src, mesa, linux-6.14) are reference-only and never committed; `vendor/SOURCES.md` records the pins.

## Build and validate (dev host, macOS 15 x86_64)

```sh
cd scripts
./build.sh 40            # compile every AMD/DRM/TTM source; rank remaining errors -> 900/900
./rt.sh                  # rebuild runtime against current headers -> 77/77
./link.sh out            # link out/Raphaeli.kext (x86_64, macOS 15+)
kmutil inspect -V tb     # sanity-check the boot kernel collection
./package.sh 1.0.2       # dist/Raphaeli-1.0.2-x86_64.zip (kext + RADV libs + firmware + tools)
```

Tests (no system changes):

```sh
cd scripts && ./install.test.sh ./oc-install.test.sh
clang++ -std=c++17 -I Raphaeli/Kernel scripts/tests/nmx_fb_edid_test.cpp && ./a.out
```

Install routes: OpenCore (black-screen-safe, `tools/oc-install.py`) or direct kextload via `scripts/install.sh` (stages firmware through `Raphaeli/Firmware/stage.sh`, builds an offline aux KC). Both are opt-in: the driver only attaches with the `raphaeli-amd=1` boot-arg, and a boot-guard NVRAM marker parks it after a failed attach.

## Bring-up sequence

1. **Capture hardware facts:** APU model, PCI IDs/revision, SMBIOS/ACPI, macOS build, firmware/BIOS settings, and which GPU currently drives the display. Keep a separate boot/recovery path.
2. **Reproduce the AMDGPU port build:** `scripts/build.sh` + `rt.sh` + `link.sh` against the target macOS SDK. Done end-to-end on the dev host (see counts above); do not install yet.
3. **Validate Phoenix support in AMDGPU:** check the exact upstream kernel driver family, firmware names/blobs and lawful provenance, IP block sequence, BAR sizing, GART/VM, reset and ring paths against the target ID. Add only verified IDs and firmware mappings. Do not force an unrelated device ID to pass probe.
4. **Safe hardware probe:** keep matching opt-in. Capture each attach stage and ensure a failed init releases PCI/BAR/interrupt resources. Test on a machine where losing GPU output does not lose the only recovery route. The reference project says its kext has not been loaded on hardware; its 41-chip RADV test is a noop DRM shim test.
5. **Render before display:** confirm kernel claim, `/dev/dri/renderD*`, `drmGetVersion`, RADV physical-device discovery, compute pipeline and readback on the actual 780M. Stress memory, fences, resets, suspend/resume, and repeated boots.
6. **Display:** only after stable render bring up framebuffer mode set/scanout and handoff. The reference bridge supports a limited mode and is explicitly unfinished.
7. **Metal:** integrate the AMD branch of NMXAccel/plugin, load RADV through libdrm and validate a small Metal subset. Then expand AIR translation/runtime coverage and Apple-semantic checks; do not claim feature parity prematurely.

## Local limits and legal gates

- Development host is an x86_64 macOS 15.7.8 (24G824) Hackintosh with AMFI and Secure Boot disabled (kexts need no signing), but it has no Radeon 780M - Phoenix GPU initialization can only be validated on the target machine. A matching KDK (KDK_15.7.8_24G824) is installed for kernel-collection validation.
- Mesa/libdrm pins and the drm-kmod/FreeBSD LinuxKPI revisions are recorded in `vendor/SOURCES.md`; the trees live under `research/`.
- The source tree derives from FreeBSD LinuxKPI/drm-kmod and includes multiple licenses. Before distribution, audit exact compiled files, their SPDX identifiers, all dependencies, and applicable source-offer obligations. Never distribute firmware without verifying its license and checksum.
- The reference AMD kext/display bridge is an unvalidated prototype. Do not install it on a daily-boot system without tested recovery.

## Status

The port builds and links end-to-end on the dev host (900/900 kernel sources, 77/77 runtime sources, `Raphaeli.kext` ~10.9 MB; only kernel-provided IOKit/libkern symbols remain undefined), packages as `dist/`, and has offline install tooling with tests. It has not been loaded on hardware. The NPU lane is parked in `Raphaeli/Attic/`. This does not claim Radeon 780M macOS support.
