# libdrm (core + amdgpu) build for macOS x86_64 — report

## Source decision
- gpu-port worktree `/Users/yuuki/Documents/tretrauit/code/Raphaeli/research/nvidia-macos-driver/gpu-port/libdrm` verified at pin `b97cbde15c5c...` (clean, `git log --oneline -5` shows `b97cbde amdgpu: add missing marketing names...`), but `grep -c __APPLE__ xf86drm.c` = 0 and 0 in `amdgpu/` — the worktree is UNPATCHED. Unusable as-is.
- Fell back per instructions: fresh copy of `/Users/yuuki/Documents/tretrauit/code/Raphaeli/research/libdrm` (verified same pin `b97cbde15c5c3abfe44d78e8f57139e50f612fec`, clean tree) to `/Users/yuuki/Documents/tretrauit/code/Raphaeli/out/src/libdrm` (`.git` stripped from the copy), then applied `/Users/yuuki/Documents/tretrauit/code/Raphaeli/Raphaeli/libdrm-macos.patch` (identical to `gpu-port/patches/libdrm-macos.patch`, byte-for-byte) via `patch -p1`. Patch touches: `libdrm_macros.h` (Darwin drm_mmap/drm_munmap via NullMoth ioctls), `meson.build` (allow darwin host), `xf86drm.c` (Darwin node detection/PCI parsing + drmNmxMmap/drmNmxMunmap implementation).

## Commands
```
cp -R research/libdrm out/src/libdrm   # fresh copy, .git removed
cd out/src/libdrm && patch -p1 < ../../Raphaeli/libdrm-macos.patch
meson setup build-darwin -Dprefix=/Users/yuuki/Documents/tretrauit/code/Raphaeli/out/usr \
  -Damdgpu=enabled -Dintel=disabled -Dradeon=disabled -Dnouveau=disabled -Dvmwgfx=disabled \
  -Dtests=false -Dman-pages=disabled
ninja -C build-darwin install
```
Configure succeeded first try; no further edits to the copy were needed beyond the patch (zero manual edits logged).

## Verification
- `file`: `libdrm.2.dylib` and `libdrm_amdgpu.1.dylib` are Mach-O 64-bit x86_64 shared libraries.
- `otool -L libdrm_amdgpu.1.dylib`: links `@p/libdrm_amdgpu.1.dylib` -> `libdrm.2.dylib` (in prefix) + libSystem only.
- `nm -gU libdrm.2.dylib` exports both `drmNmxMmap` and `drmNmxMunmap`.
- `PKG_CONFIG_PATH=out/usr/lib/pkgconfig pkg-config --modversion libdrm libdrm_amdgpu` → `2.4.134 2.4.134`; `--libs libdrm_amdgpu` → `-L.../out/usr/lib -ldrm_amdgpu`.

## Install tree (`/Users/yuuki/Documents/tretrauit/code/Raphaeli/out/usr`)
```
lib/libdrm.2.dylib            (90.5K)
lib/libdrm.dylib -> libdrm.2.dylib
lib/libdrm_amdgpu.1.dylib     (56.9K)
lib/libdrm_amdgpu.dylib -> libdrm_amdgpu.1.dylib
lib/pkgconfig/libdrm.pc
lib/pkgconfig/libdrm_amdgpu.pc
include/libdrm/ (amdgpu.h, amdgpu_drm.h, drm.h, drm_fourcc.h, drm_mode.h, ... all UAPI headers)
share/libdrm/amdgpu.ids
```

## NMXGPU kext-ABI gap verification (follow-up, per /tmp/raphaeli-reports/kext-abi.md)
Verified against the built copy `out/src/libdrm` (patch applied) and kext header `Raphaeli/xkpi/bsdcompat/include/nmx_drm_uapi.h`:

1. **BSD-ioccom ioctl encoding — COVERED.** `include/drm/drm.h`: on `__APPLE__` falls into the `#else /* One of the BSDs */` branch → `<sys/ioccom.h>`; all `DRM_IOCTL_*` are `DRM_IO/DRM_IOR/DRM_IOW/DRM_IOWR` = `_IO/_IOR/_IOW/_IOWR` (drm.h:1089-1092). `xf86drm.h:41` also includes `<sys/ioccom.h>`. Matches kext's `__FreeBSD__`-branch encoding.
2. **NMX mmap ioctls for bo map/munmap — COVERED.** `amdgpu/amdgpu_bo.c:468` `drm_mmap(NULL, size, prot, MAP_SHARED, fd, args.out.addr_ptr)` → patched `libdrm_macros.h` `__APPLE__` branch → `drmNmxMmap` → `NMX_DRM_IOCTL_MMAP`; `:503` `drm_munmap` → `drmNmxMunmap` → `NMX_DRM_IOCTL_MUNMAP`. Patch's defines `_IOWR('N',0x40,struct nmx_drm_mmap)` / `_IOW('N',0x41,struct nmx_drm_munmap)` and struct layouts are byte-identical to `nmx_drm_uapi.h:13-22,41-42`. Fallback to `mmap(2)` only on `ENOTTY`.
3. **GET_PCIINFO enumeration — COVERED.** `xf86drm.c:99` `DRM_IOCTL_GET_PCIINFO = DRM_IOR(0x15, struct drm_pciinfo)` (ioccom); `drmParsePciBusInfo` (:3759-3771) and `drmParsePciDeviceInfo` (:3930) take `__APPLE__` branches issuing it, matching kext's node-answered `nmx_drm_node_ioctl`. Node discovery via `drm_darwin_node_exists` (:109, :3340).
4. **Degraded poll — COVERED (no action needed).** No `select`/`poll` blocking calls in `amdgpu/*.c`; libdrm-amdgpu does not rely on blocking poll. Tolerance is inherent.

Status of the pinned gpu-port worktree itself: it does NOT carry these adaptations in-tree (0 `NMX`/`__APPLE__` hits in `xf86drm.c`/`amdgpu/`; its `include/drm/drm.h:47` does include `<sys/ioccom.h>`). The adaptations live in `gpu-port/patches/libdrm-macos.patch` (= `Raphaeli/libdrm-macos.patch`), which my build applies. **No edits made to the pinned worktree; git status clean, zero uncommitted changes, history untouched.**

## Notes / residual risks
- Automated pi-lens diagnostics flagged vendored Linux UAPI headers (exynos/tegra/intel) — false positives; those drivers are disabled and were never compiled.
- `drmNmxMmap` falls back to plain `mmap(2)` on `ENOTTY` (non-NullMoth nodes, e.g. drm-shim). On macOS without the NullMoth kext, device-dependent paths (real GPU mmap) won't work; core/amdgpu API layer builds and links fine.
