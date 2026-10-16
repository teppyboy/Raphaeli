# pkg installer lane — native .pkg installer

`scripts/make-pkg.sh [out-dir] [--with-kext]` builds `dist/Raphaeli-<hash>-x86_64.pkg`
with `pkgbuild` + `productbuild` (no shell-script download, no zip). Built and validated
on macOS 15.7.8 (24G824), commit `e027e5d`.

## Contents

| Component | id | Payload | installKBytes |
|---|---|---|---|
| usr-local | `me.tretrauit.raphaeli.pkg.usrlocal` | `/usr/local/share/vulkan/icd.d/radeon_icd.x86_64.json` + `/Library/Raphaeli/usr/lib/{libdrm.2.dylib,libdrm_amdgpu.1.dylib,libvulkan_radeon.dylib}` | 26 660 |
| framework | `me.tretrauit.raphaeli.pkg.framework` | `/Library/Raphaeli/firmware/amdgpu/*.bin` (14 blobs) | 3 236 |
| kext (`--with-kext`) | `me.tretrauit.raphaeli.pkg.kext` | `/Library/Extensions/Raphaeli.kext` (`--ownership preserve` + postinstall `chown -R root:wheel`) | 10 736 |

Pkg sizes: **7.3 MB** (userspace+firmware), **11.1 MB** (with kext). Distribution:
`title "Raphaeli 780M driver (userspace + firmware)"`, `<os-version min="14.0"/>`,
`allow-external-scripts="false"`, `customize="never"`, product id
`me.tretrauit.raphaeli.pkg`.

## Layout notes

- Actual dylib names are the darwin meson ones (`libdrm.2.dylib`, `libdrm_amdgpu.1.dylib`),
  not the Linux-style `.so.2`/`.so.1` the payload was first specced with; the `.dylib`
  convenience symlinks in `out/usr/lib` are omitted (nothing loads by them).
- ICD json ships with absolute `library_path: /Library/Raphaeli/usr/lib/libvulkan_radeon.dylib`
  (same layout `install.sh` stages), so the Vulkan loader finds it on any target.
- The build-tree dylibs carry **absolute dev-host install names** (`/Users/.../out/usr/lib/...`,
  meson default). `make-pkg.sh` rewrites ids/dependents to `@loader_path/...` with
  `install_name_tool` on the staged copies, so the payload loads from
  `/Library/Raphaeli/usr/lib` on any machine. Build-side fixups belong to the build lane.
- Postinstall only: chowns the kext to root:wheel if present, prints a summary. It does
  **not** write boot-args (`nvram` belongs to `oc-install.py` / `recovery-install.sh`) and
  does **not** run `kmutil` — the auxKC rebuild must happen on the **booted** system
  (kernelmanagerd / `kmutil install` with a matching KDK), never from RecoveryOS where the
  on-disk System/Boot collections of the target aren't the ones Recovery booted from.

## Validation performed (dev host, no install)

```text
./scripts/make-pkg.sh dist
./scripts/make-pkg.sh dist --with-kext
pkgutil --payload-files dist/Raphaeli-e027e5d-x86_64.pkg     # full payload tree listed
pkgutil --check-signature dist/Raphaeli-e027e5d-x86_64.pkg   # "no signature" (expected)
installer -pkg dist/... -target / -volinfo                   # volumes: /
pkgutil --expand ... ; tar -xf */Payload; otool -L staged dylibs  # @loader_path verified
```

No installation was run on the dev host (`installer --dry-run` is not supported by
Apple's `installer`; inspection-only checks used instead).

## RecoveryOS invocation

Booted into RecoveryOS (or another volume's OS), with the target volume mounted at
`/Volumes/<vol>`:

```bash
installer -pkg /Volumes/<src>/Raphaeli-e027e5d-x86_64.pkg -target "/Volumes/<vol>"
```

- Files land under `<vol>/usr/local/...`, `<vol>/Library/Raphaeli/...`,
  `<vol>/Library/Extensions/...`. The postinstall chown runs against the target.
- After installing the kext variant, the auxKC rebuild and the `raphaeli-amd=1` boot-arg
  must be applied later on the booted target (`install.sh` / `oc-install.py`).
- `-target /` in RecoveryOS targets the Recovery ramdisk, not the real system — always
  pass the mounted target volume explicitly.

## GUI Gatekeeper caveat

The pkg is **unsigned**. CLI `installer` accepts it as-is. Double-clicking in Finder
triggers Gatekeeper ("unidentified developer"); on a downloaded copy either right-click →
Open, or `xattr -d com.apple.quarantine <pkg>`. Future option: `productbuild --sign`
with a Developer ID Installer cert.

## package.sh integration (one line, not applied)

In `scripts/package.sh`, next to the existing zip line:

```bash
./scripts/make-pkg.sh "$STAGE" --with-kext   # leaves "$STAGE/Raphaeli-$VERSION-$ARCH.pkg" beside the zip
```

## Residual risks

- `libvulkan_radeon.dylib` still links homebrew deps by absolute path
  (`/usr/local/opt/zstd/lib/libzstd.1.dylib`, `/usr/local/opt/spirv-tools/lib/libSPIRV-Tools.dylib`)
  plus system `libexpat`/`libc++`. On a clean target without those paths the ICD fails to
  load — build lane should vendor/static-link them; until then the pkg is dev-host-shaped
  for userspace.
- Unsigned product; GUI installs need the quarantine workaround.
- Kext payload ships root:wheel only after postinstall runs; booting/kmutil steps stay
  owned by the other lanes.
