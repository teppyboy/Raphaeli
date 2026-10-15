# Radeon 780M macOS graphics stack

Goal: bring up AMD Phoenix/RDNA3 APU graphics on x86_64 macOS with the same broad split as the AMD path in `research/nvidia-macos-driver/`: an `amdgpu`-based kernel/DRM port, Mesa RADV user-space Vulkan, then the AMD-capable Metal accelerator/plugin path using `metal2vulkan` where appropriate.

```text
Metal apps → Metal plugin → AIR-to-SPIR-V/runtime → RADV → libdrm/DRM node → AMDGPU XNU kext → Radeon 780M
```

The pieces are distinct: Mesa's RADV and `metal2vulkan` do not initialize the GPU or replace an AMD kernel driver. The AMD kext must provide working PCI/resource setup, AMD firmware loading, GPU memory/VM, scheduling/submission, interrupts, fences, and a user-visible DRM node. Display/IOKit handoff is another milestone.

## Repository baseline

The local `research/nvidia-macos-driver/gpu-port/` already has an experimental AMD path: `xkpi/build.sh` compiles drm-kmod's AMDGPU/DRM/TTM sources, `xkpi/link.sh` builds `Raphaeli.kext`, Mesa/libdrm have macOS patches, and the NMXAccel/plugin path includes AMD RADV support. That is a better starting point than a new driver implementation or repurposing NootRX/NootedRed.

A shallow Mesa clone is in `research/mesa/` at `d44453ce07ba5e1e6b71f7960809c38f2526c1cd` (upstream `main` at clone time); exact GPU-port Mesa/libdrm revisions are vendored under `research/nvidia-macos-driver/gpu-port/{mesa,libdrm}/`. Mesa's AMD common code identifies Phoenix (`CHIP_PHOENIX`) as `gfx1103`; its simulated Phoenix entry uses PCI device ID `0x15bf` in `src/amd/common/amdgpu_devices.c`. Confirm the actual target APU IDs before device-specific binding; a simulator entry does not prove macOS hardware support.

## Bring-up sequence

1. **Capture hardware facts:** APU model, PCI IDs/revision, SMBIOS/ACPI, macOS build, firmware/BIOS settings, and which GPU currently drives the display. Keep a separate boot/recovery path.
2. **Reproduce the AMDGPU port build:** source pins are recorded in `Raphaeli/vendor/SOURCES.md`, and the xkpi port copy is under `Raphaeli/xkpi/`. Build/link and run `kmutil create` against the target macOS SDK; do not install yet. Build scripts still need a portable root and dependency layout.
3. **Validate Phoenix support in AMDGPU:** check the exact upstream kernel driver family, firmware names/blobs and lawful provenance, IP block sequence, BAR sizing, GART/VM, reset and ring paths against the target ID. Add only verified IDs and firmware mappings. Do not force an unrelated device ID to pass probe.
4. **Safe hardware probe:** keep matching opt-in. Capture each attach stage and ensure a failed init releases PCI/BAR/interrupt resources. Test on a machine where losing GPU output does not lose the only recovery route. The reference project says its kext has not been loaded on hardware; its 41-chip RADV test is a noop DRM shim test.
5. **Render before display:** confirm kernel claim, `/dev/dri/renderD*`, `drmGetVersion`, RADV physical-device discovery, compute pipeline and readback on the actual 780M. Stress memory, fences, resets, suspend/resume, and repeated boots.
6. **Display:** only after stable render bring up framebuffer mode set/scanout and handoff. The reference bridge supports a limited mode and is explicitly unfinished.
7. **Metal:** integrate the AMD branch of NMXAccel/plugin, load RADV through libdrm and validate a small Metal subset. Then expand AIR translation/runtime coverage and Apple-semantic checks; do not claim feature parity prematurely.

## Local limits and legal gates

- Development host is an x86_64 macOS 15.7.8 (24G824) Hackintosh with AMFI and Secure Boot disabled (kexts need no signing), but it has no Radeon 780M - Phoenix GPU initialization can only be validated on the target machine. A matching KDK (KDK_15.7.8_24G824) is installed for kernel-collection validation.
- Full GPU-port Mesa/libdrm revisions and the drm-kmod/FreeBSD LinuxKPI sources have been fetched under `research/`; `Raphaeli/vendor/SOURCES.md` records revisions. The xkpi build still needs portability cleanup and has not been run end-to-end.
- The reference AMD kext/display bridge is an unvalidated prototype. Do not install it on a daily-boot system without tested recovery.
- The NVIDIA driver tree has mixed licensing (including PolyForm Noncommercial components); Mesa and `metal2vulkan` have their own licenses. Keep dependency notices, audit every copied file and firmware blob, and decide redistribution terms before publishing.

## Status

Local kext base and Mesa sources are now staged for continued development, but the AMDGPU port has not been built, installed, or loaded. Next: finish portable build setup, compile/link and validate offline, then get target hardware IDs and a recoverable bare-metal test system. This does not claim Radeon 780M macOS support.
