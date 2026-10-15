# Mesa RADV build for macOS x86_64 (Raphaeli NMXGPU, Phoenix/gfx1103)

Date: 2026-10-15. Status: **SUCCESS** — libvulkan_radeon.dylib built, installed.

## Source
- Upstream: `research/nvidia-macos-driver/gpu-port/mesa` at pin `bffd91947ef` (26.3.0-devel, Mesa gpu-port authors' tree).
- Copied (unmodified) to `/Users/yuuki/Documents/tretrauit/code/Raphaeli/work-mesa` per policy; nothing in `research/` touched.
- Applied `research/nvidia-macos-driver/gpu-port/patches/mesa-macos.patch` to the copy (`git apply`, clean, 11 modified files + 1 new file `src/drm-shim/drm_shim_darwin.c`). No hand edits of our own.
- `patches/mesa-macos.patch` contents (per gpu-port README): Darwin as KMS/DRM system, `os_sync_wait_on_address` futexes, `vk_image` Apple guards, `b_lundef=false` on darwin, addrlib portable path, drm-shim Darwin front end, POSIX shm in place of memfd.

## Dependencies
- libdrm 2.4.134 (prior lane) at `out/usr` — found via `PKG_CONFIG_PATH=/Users/yuuki/Documents/tretrauit/code/Raphaeli/out/usr/lib/pkgconfig` (libdrm + libdrm_amdgpu).
- Apple clang 17 (x86_64 host — native build, no cross file needed).
- brew llvm 23.1.3 present (not required for radv object-code path).
- Installed during build (env, not code changes): brew `glslang` 16.6.0 (required: `with_bvh` for amd_vk, needs >= 12.2 preamble), python3.15 modules `mako`, `pyyaml`, `packaging` (mesa meson.build python checks exit(2) without `packaging` on py3.15 — no distutils).

## Configure line
```
cd /Users/yuuki/Documents/tretrauit/code/Raphaeli/work-mesa
PKG_CONFIG_PATH=/Users/yuuki/Documents/tretrauit/code/Raphaeli/out/usr/lib/pkgconfig \
meson setup --wipe build-darwin \
  -Dprefix=/Users/yuuki/Documents/tretrauit/code/Raphaeli/out/usr \
  -Dvulkan-drivers=amd -Dgallium-drivers= -Dglx=disabled -Dplatforms= \
  -Dbuild-tests=false -Dtools=
```

## Build
- `ninja -C build-darwin src/amd/vulkan/libvulkan_radeon.dylib` — completed (772 targets), 0 errors, 0 warnings in final pass.
- `ninja -C build-darwin install` — 0 errors.

## Artifacts
- `work-mesa/build-darwin/src/amd/vulkan/libvulkan_radeon.dylib` (27.1 MB, Mach-O 64-bit x86_64)
- `/Users/yuuki/Documents/tretrauit/code/Raphaeli/out/usr/lib/libvulkan_radeon.dylib` (installed)
- `/Users/yuuki/Documents/tretrauit/code/Raphaeli/out/usr/share/vulkan/icd.d/radeon_icd.x86_64.json` (ICD JSON; `library_path` = installed dylib)

## Verification
- `file`: Mach-O 64-bit dynamically linked shared library x86_64.
- `otool -L`: links `@rpath`-free `libdrm_amdgpu.1.dylib` and `libdrm.2.dylib` under `out/usr/lib` (install_name_mode set by install).
- `nm -gU`: exports `_vk_icdGetInstanceProcAddr`.
- Runtime probe NOT run (requires NMXGPU kext `/dev/dri` nodes + `nmxamd=1` boot arg; out of scope for this lane).

## Error census
- Configure errors (all resolved): glslangValidator missing (1) → brew install glslang; "Python >= 3.10 not found" (2, staged: missing mako/yaml, then missing `packaging` on py3.15) → pip install mako pyyaml packaging.
- Build errors: 0. Build warnings: 0 (final incremental passes). Linker warning: duplicate `-lSystem -lexpat -lz` ignored (benign).
- Remaining build blockers: **none**.

## Notes
- File changes in `work-mesa`: only those from `mesa-macos.patch` (11 modified: meson.build, src/amd/vulkan/meson.build, src/intel/meson.build, src/intel/vulkan/meson.build, src/drm-shim/{device.c,drm_shim.h,meson.build}, src/util/futex.{c,h}, src/vulkan/runtime/vk_image.{c,h}; 1 added: src/drm-shim/drm_shim_darwin.c). No research/ tree modified.
