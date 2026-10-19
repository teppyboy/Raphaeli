# recovery-install.sh — installer lane for macOS RecoveryOS

## What
`scripts/recovery-install.sh`: complete Raphaeli driver installer designed to run
from the macOS RecoveryOS shell (root, no GUI, kextload impossible, WindowServer
crashing on the normal volume). Plain bash 3.2 + coreutils — exactly what
RecoveryOS ships (no bash-4 features: no associative arrays, no coproc; the
whole suite is verified under `/bin/bash` 3.2.57).

History: a single-file C version (`recovery-install.c`) briefly replaced this
per a direction change and was reverted by user decision — the bash script is
the deliverable (commit `c5c5e3b` introduced it, `1f98a92` briefly replaced it
with C, and the current commit restores it, keeping the extra test checks the
C-era harness added).

Wired into `scripts/package.sh` (tools/ copy + INSTALL.md section "Installing
from macOS Recovery") and covered by `scripts/recovery-install.test.sh`
(47 checks, all passing).

## Environment assumptions handled
1. **Target volume is not `/`** — appears under `/Volumes/<name>`. Auto-detects
   the unique candidate (prefers volumes with `Library/Extensions`); requires an
   explicit volume argument when ambiguous, printing the usage line and the
   candidate list. `RAPHAELI_VOLUMES_DIR` env override exists as a test hook.
2. **APFS** — tries `mount -uw <vol>`, ignores failure if already rw.
3. **Sealed System Volume** — `/usr/lib` on the system snapshot is unwritable:
   dylibs go to `<vol>/Library/Raphaeli/usr/lib/` and the Vulkan ICD json is
   written to `<vol>/usr/local/share/vulkan/icd.d/radeon_icd.x86_64.json`
   (Data volume, writable; the Vulkan loader default-scans it) with an ABSOLUTE
   `library_path` of `/Library/Raphaeli/usr/lib/libvulkan_radeon.dylib`. If
   discovery still fails, the printed notes document
   `VK_DRIVER_FILES=/usr/local/share/vulkan/icd.d/radeon_icd.x86_64.json`
   (no `etc/paths.d` file is created).
4. **Kext + firmware** — `ditto` to `<vol>/Library/Extensions/Raphaeli.kext`,
   `chown -R root:wheel`, `chmod -R 755`; firmware staged via the dist's
   `tools/fw/stage.sh` into `<vol>/Library/Raphaeli/firmware/amdgpu/`, after a
   census against the 11 required `request_firmware()` names plus optional
   firmware and optional `SHA256SUMS` verification via `shasum -a 256 -c` (skipped if the package
   ships no manifest).
5. **Boot-args + boot guard** — mirrors install.sh exactly: `raphaeli-amd=1`
   appended to `nvram boot-args` only with `--apply` (idempotent, preserves
   pre-existing args); `--uninstall` strips it (`nvram -d boot-args` when it was
   the only arg) and clears the `raphaeli-gpu-attaching` guard marker.
6. **OC detection** — if `<vol>/EFI/OC/config.plist` exists: skips kext copy and
   auxKC entirely (OC injects), installs only firmware + userspace, and points
   the user at `oc-install.py` on the booted system. config.plist is never
   edited from Recovery.
7. **auxKC (direct path)** — best effort: if `kmutil` exists and the target
   volume has `System/Library/KernelCollections`, it reads the target's
   `ProductBuildVersion` via `plutil` and looks for a matching KDK under
   `<vol>/Library/Developer/KDKs`; builds `Raphaeli.auxkc` via
   `kmutil create -a x86_64 -n aux -x`. If kmutil/KDK is absent (or kmutil
   fails) it prints the on-macOS follow-up: `sudo ./tools/install.sh kext/Raphaeli.kext --apply`.
8. **Safety** — `--dry-run` prints every mutating action (including the ICD json
   write and `mount -uw`) and never runs them; every failure exits non-zero with
   a clear message. Apply mode stages userspace, ICD, firmware, kext, and auxKC
   outputs beside their destinations, then publishes them with rollback backups;
   any later failure restores the original files and removes transaction paths.
9. **Target preflight** — `--target` always validates `SOURCE.lock`, including
   when `RAPHAELI_KEXT` overrides the selected bundle source. The override does
   not bypass target safety gates.

## Usage
```bash
recovery-install.sh /Volumes/Macintosh\ HD --target sequoia [--apply] [--dry-run]
recovery-install.sh /Volumes/Macintosh\ HD --uninstall
```

## Layout notes
Source resolution mirrors the dist zip (tools/ sibling of kext/, usr/lib/,
firmware/) with dev-tree fallback (out/Raphaeli.kext, out/usr/lib). Packaged target
bundles are selected explicitly; package.sh rejects stale vendor-wide PCI personalities.
Source-tree
overrides: `RAPHAELI_KEXT`, `RAPHAELI_FW_SRC`.

## Test coverage (scripts/recovery-install.test.sh)
Fake dist tree + fake volumes in a temp dir, mocked `nvram` (state-file shim on
PATH, run under `/bin/bash` 3.2): explicit/ambiguous/auto volume detection +
usage output; target preflight with and without `RAPHAELI_KEXT`; dry-run prints
and never touches nvram; apply-mode real file placement (dylibs, firmware,
kext, ICD json with absolute library_path); injected firmware failure verifies
userspace, ICD, firmware, kext, and transaction artifacts roll back unchanged;
boot-args appended preserving existing args, idempotent re-apply; OC-detect
skips kext copy but still stages firmware/userspace; SHA256SUMS good/bad;
uninstall removes kext/firmware/ICD + strips boot-arg (lone-arg case removes
boot-args entirely) + clears the guard marker; help/bad-option/bad-volume/
bad-bundle-id failures.

## Known limitations
- `mount -uw` failure is tolerated silently; if the Data volume stays read-only
  the subsequent writes fail loudly with non-zero exit (correct behavior).
- The auxKC path is untestable off-target (needs kmutil + KDK + real kernel
  collections); guarded by existence checks and best-effort with printed
  follow-up.
- `chown`/`chmod` failures when not root print a warning instead of dying (the
  test harness runs as a normal user; in Recovery the shell is root).
- SHA256SUMS verification relies on `shasum` (perl); if a future RecoveryOS
  drops perl the manifest check should move into the kext-side or a compiled
  helper (currently skipped only when no manifest is shipped).

## Follow-up lane (documented, not implemented)
A planned follow-up will **embed the firmware blobs into the kext bundle's
`Contents/Resources/`** (instead of / alongside the `/Library/Raphaeli/firmware`
staging), so that an OC-injected setup covers everything — firmware, userspace
dependencies and kext — through OC injection alone, with no separate firmware
staging step needed on the target volume. This touches `nmx_platform.cpp`'s
firmware lookup path and `package.sh` assembly; it supersedes the
"OC mode still stages firmware" behavior above once landed.
