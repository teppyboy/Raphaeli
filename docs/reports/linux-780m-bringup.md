# Linux Radeon 780M bring-up evidence

Source: user-provided `/Users/yuuki/Downloads/out.txt`, collected on Fedora 44
Workstation. This records Linux evidence only; it does not establish macOS
attach, IOAccel ABI, or runtime behavior.

## Identified hardware and stack

- CPU: AMD Ryzen 7 8745H with Radeon 780M Graphics.
- Integrated GPU: PCI `1002:1900`, revision `b4`, subsystem Lenovo `17aa:3814`,
  at `0000:63:00.0`; Linux names it HawkPoint1.
- `1002:1900` differs from the project's presumed Phoenix ID `1002:15bf`.
  Linux labels it HawkPoint1; the supplied runtime log says gfx IP block
  `gfx_v11_0_0`, while this repo's firmware census stages GC 11.0.1 blobs. This
  raises a compatibility question but proves neither compatibility nor
  incompatibility. Exact IP-discovery contents, active firmware filenames and
  reported firmware versions are still needed before changing device matching
  or the firmware bundle.
- Fedora 44 x86_64, kernel `7.2.9-201.fc44.x86_64`, amdgpu loaded. DRM driver
  initialized as `amdgpu 3.64.0`; log reports `gfx_v11_0_0`, `sdma_v6_0_0`, VCN
  4, MES 11 and DCN 3.1.4 / display core 3.2.384.
- VRAM reported 2048 MiB, 128-bit LPDDR5; GTT 10901 MiB; GPU VM is 4-level,
  262144 GB address space. `renderD128` exists and belongs to group `render`.
- Vulkan enumerates AMD `0x1002:0x1900`, Radeon 780M Graphics (RADV Phoenix),
  RADV / Mesa 26.2.4. GLX reports radeonsi, Phoenix, ACO, accelerated yes,
  OpenGL 4.6. These prove Linux userspace acceleration on that machine.

## Firmware and kernel log

The supplied boot log shows IP discovery, PSP/SMU initialization, DMUB, GART,
ring registration, and amdgpu DRM initialization. Optional RAS/RAP/secure-display
firmware notices appear, but no GPU reset, VM fault, or ring timeout is visible
in the excerpt. `modinfo` lists many firmware names but does not prove which
exact files were loaded. Treat this as bring-up evidence, not a firmware census.

## Raphaeli relevance

1. This is a real 780M Linux system, not macOS. It cannot validate
   IOAccelerator, IOGraphicsFamily, IOAccel task cleanup, Metal, or RecoveryOS.
2. The main `Raphaeli` AMD service has a vendor-wide personality and probe-time
   opt-in. `RaphaeliFB` is currently matched only to `0x15bf`, so this system's
   `0x1900` function would not match that framebuffer personality today. Do not
   widen the match until PCI/IP/firmware identity and macOS probe safety are
   validated.
3. The subsystem, VBIOS identity, exact IP discovery data, and active firmware
   names/versions would be useful for reconciling the AMD IDs and firmware path.
   No source SKU or match was changed based on this report alone.

## Next useful capture

Capture active AMD firmware filenames and hashes, exact IP-discovery data if
available, and firmware-reported versions from dmesg. A controlled Vulkan
compute/readback result would further prove Linux GPU execution. No driver reload,
firmware change, or destructive stress test is needed for this evidence.
