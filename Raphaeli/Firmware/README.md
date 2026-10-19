# AMD firmware staging (Phoenix / Radeon 780M / gfx1103, PCI 0x15bf)

The kext reads blobs from `FIRMWARE_ROOT` = `/Library/Raphaeli/firmware/`
(`xnu/nmx_platform.cpp`) via `nmx_xnu_firmware_load`, called from
`bsdcompat/src/nmx_firmware.c: firmware_get()`. amdgpu requests names like
`amdgpu/gc_11_0_1_pfp.bin`, so files land at
`/Library/Raphaeli/firmware/amdgpu/<name>.bin`.

Since DCN 3.1.4 era asics (Phoenix included) the driver builds the file set from
IP discovery, not per-chip lists in `amdgpu_drv.c`.

## Exact file set for Phoenix (from this tree's request_firmware sites)

| File | Source |
|---|---|
| `ip_discovery.bin` | `amdgpu_discovery.c` (optional; discovery may use firmware/BIOS data) |
| `gc_11_0_1_pfp.bin`, `_me.bin`, `_rlc.bin`, `_mec.bin` | `gfx_v11_0.c` (GC IP 11.0.1) |
| `gc_11_0_1_imu.bin` | `imu_v11_0.c` (IMU funcs set for all gfx11 APUs) |
| `gc_11_0_1_mes1.bin` (+ `gc_11_0_1_mes_2.bin` w/ fallback `_mes.bin`) | `amdgpu_mes.c`; MES enabled by default on GC 11.0.1 (`amdgpu_discovery.c: amdgpu_discovery_set_mes_ip_blocks`) |
| `sdma_6_0_2.bin` | `sdma_v6_0.c` |
| `psp_13_0_11_toc.bin`, `_ta.bin` | `psp_v13_0.c` (MP0 13.0.11; no sos, no cap file for 13.0.11) |
| `vcn_4_0_2.bin` | `amdgpu_vcn.c` (Phoenix1 UVD 4.0.2); `vcn_4_0_4.bin` is Phoenix2 — JPEG shares the VCN blob, no separate jpeg file |
| `dcn_3_1_4_dmcub.bin` | `display/amdgpu_dm/amdgpu_dm.c` (FIRMWARE_DCN_314_DMUB); no DMCU file on DCN3 |
| `gc_11_0_1_toc.bin` | optional; only when fw load type is RLC_BACKDOOR_AUTO (Phoenix uses PSP) |

No SMU file: MP1 13.0.8 uses `yellow_carp_ppt.c`, which has no `load_microcode`
— the SMC firmware is preloaded by the BIOS (there is no `smu_13_0_8.bin` in
linux-firmware).

## Getting the blobs

No Phoenix blobs are vendored anywhere in this tree (checked `research/NootedRed`
= GC 9.x only; `research/nvidia-macos-driver/gpu-port` vendors none). Fetch the
`amdgpu/` directory from the [linux-firmware](https://gitlab.com/freedesktop.org/drm/misc/kernel/-/tree/firmware/amdgpu)
repo (or a distro `linux-firmware` package) and run:

    xkpi/fw/stage.sh <path-to-blobs> /Library/Raphaeli/firmware

Licensing: these are redistributable per linux-firmware LICENSE.amdgpu; verify
checksums before distribution (see xkpi/README.md note).
