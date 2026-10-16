# recovery-install — installer lane for macOS RecoveryOS

## What
Single-file C program `scripts/recovery-install.c` (supersedes the earlier bash
`scripts/recovery-install.sh`, which was removed): a complete Raphaeli driver
installer designed to run from the macOS RecoveryOS shell (root, no GUI,
kextload impossible, WindowServer crashing on the normal volume).

- Build: `clang -O2 -Wall -o recovery-install recovery-install.c` (libSystem
  only; no external deps). `scripts/package.sh` compiles it at package time
  (`-arch x86_64 -mmacosx-version-min=15.0`, built on the macOS 15 dev host,
  verified to link) and ships **both the binary and the source** as
  `tools/recovery-install` + `tools/recovery-install.c` in the dist zip.
- `scripts/gen_ccdb.sh` carries a clangd entry so the file lints against the
  real macOS SDK.
- Tests: `scripts/recovery-install.test.sh` compiles the program with
  `-O2 -Wall` (warnings fail the run) and drives the binary against a fake
  dist tree + fake volumes in a temp dir with a mocked `nvram` on PATH
  (49 checks, all passing).

## Environment assumptions handled
1. **Target volume is not `/`** — appears under `/Volumes/<name>`. Auto-detects
   the unique candidate (prefers volumes with `Library/Extensions`); requires an
   explicit volume argument when ambiguous, printing the usage line and the
   candidate list. `RAPHAELI_VOLUMES_DIR` env override exists as a test hook.
2. **APFS** — spawns `mount -uw <vol>`, ignores failure if already rw.
3. **Sealed System Volume** — `/usr/lib` on the system snapshot is unwritable:
   dylibs go to `<vol>/Library/Raphaeli/usr/lib/` and the Vulkan ICD json is
   written to `<vol>/usr/local/share/vulkan/icd.d/radeon_icd.x86_64.json`
   (Data volume, writable; the Vulkan loader default-scans it) with an ABSOLUTE
   `library_path` of `/Library/Raphaeli/usr/lib/libvulkan_radeon.dylib`. If
   discovery still fails, the printed notes document
   `VK_DRIVER_FILES=/usr/local/share/vulkan/icd.d/radeon_icd.x86_64.json`
   (no `etc/paths.d` file is created).
4. **Kext + firmware** — kext copied via `copyfile(COPYFILE_ALL|COPYFILE_RECURSIVE)`
   (ditto equivalent) to `<vol>/Library/Extensions/Raphaeli.kext`, then
   `chown` root:wheel + `chmod 755` over the tree (nftw); firmware blobs
   (`*.bin`) staged into `<vol>/Library/Raphaeli/firmware/amdgpu/` after a
   census against the 12 required `request_firmware()` names, plus optional
   `SHA256SUMS` verification implemented natively with CommonCrypto's
   `CC_SHA256` (skipped if the package ships no manifest; no shasum/perl
   dependency in Recovery).
5. **Boot-args + boot guard** — mirrors install.sh exactly: `raphaeli-amd=1`
   appended to `nvram boot-args` only with `--apply` (idempotent, preserves
   pre-existing args); `--uninstall` strips it (`nvram -d boot-args` when it was
   the only arg) and clears the `raphaeli-gpu-attaching` guard marker. NVRAM is
   touched exclusively via `posix_spawnp("nvram", ...)` — the IODeviceTree is
   not reimplemented.
6. **OC detection** — if `<vol>/EFI/OC/config.plist` exists: skips kext copy and
   auxKC entirely (OC injects), installs only firmware + userspace, and points
   the user at `oc-install.py` on the booted system. config.plist is never
   edited from Recovery.
7. **auxKC (direct path)** — best effort: if `kmutil` is found on PATH and the
   target volume has `System/Library/KernelCollections`, it reads the target's
   `ProductBuildVersion` via `plutil` and looks for a matching KDK under
   `<vol>/Library/Developer/KDKs`; builds `Raphaeli.auxkc` via
   `kmutil create -a x86_64 -n aux -x`. If kmutil/KDK is absent (or kmutil
   fails) it prints the on-macOS follow-up: `sudo ./tools/install.sh kext/Raphaeli.kext --apply`.
8. **Safety** — `--dry-run` prints every mutating action (including the ICD json
   write and `mount -uw`) and never runs them; every failure exits 1 with a
   clear message.

## Usage
```bash
recovery-install /Volumes/Macintosh\ HD [--apply] [--dry-run]
recovery-install /Volumes/Macintosh\ HD --uninstall
```

## Layout notes
Source resolution mirrors the dist zip (binary at `tools/`, sibling `kext/`,
`usr/lib/`, `firmware/`) with dev-tree fallback (`out/Raphaeli.kext`,
`out/usr/lib`). Overrides: `RAPHAELI_KEXT`, `RAPHAELI_FW_SRC`.

## Test coverage (scripts/recovery-install.test.sh)
Clean `-Wall` compile; explicit/ambiguous/auto volume detection + usage output;
dry-run prints and never touches nvram; apply-mode real file placement (dylibs,
firmware, kext, ICD json with absolute library_path); boot-args appended
preserving existing args, idempotent re-apply; OC-detect skips kext copy but
still stages firmware/userspace; SHA256SUMS good/bad; uninstall removes
kext/firmware/ICD + strips boot-arg (lone-arg case removes boot-args entirely)
+ clears the guard marker; help/bad-option/bad-volume/bad-bundle-id failures.

## Known limitations
- `mount -uw` failure is tolerated silently; if the Data volume stays read-only
  the subsequent writes fail loudly with non-zero exit (correct behavior).
- The auxKC path is untestable off-target (needs kmutil + KDK + real kernel
  collections); guarded by existence checks and best-effort with printed
  follow-up.
- `chown`/`chmod` failures when not root print a warning instead of dying (the
  test harness runs as a normal user; in Recovery the shell is root).

## Follow-up lane (documented, not implemented)
A planned follow-up will **embed the firmware blobs into the kext bundle's
`Contents/Resources/`** (instead of / alongside the `/Library/Raphaeli/firmware`
staging), so that an OC-injected setup covers everything — firmware, userspace
dependencies and kext — through OC injection alone, with no separate firmware
staging step needed on the target volume. This touches `nmx_platform.cpp`'s
firmware lookup path and `package.sh` assembly; it supersedes the
"OC mode still stages firmware" behavior above once landed.
