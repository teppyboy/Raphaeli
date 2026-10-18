# Raphaeli install/deploy flow — report

Task: `Raphaeli/xkpi/install.sh` for the 780M target machine. Status: implemented, dry-run tested.

## Deliverables

- `Raphaeli/xkpi/install.sh` — bash, `set -euo pipefail`, executable.
- `Raphaeli/xkpi/install.test.sh` — 16 assertions, all pass (non-privileged).

## Design / facts used

- **kmutil install vs create (man page, this host):** `kmutil install` only updates the Boot/System
  collections; it does NOT apply an aux KC. `kmutil create` only builds. The system-loaded aux KC
  lives in `/Library/KernelCollections` — this macOS 15.7.8 host has
  `/Library/KernelCollections/AuxiliaryKernelExtensions.kc` (falls back to `BootKernelExtensions.kc`
  if absent). So the correct apply step for the offline-built artifact is:
  `sudo cp /Library/KernelCollections/Raphaeli.auxkc /Library/KernelCollections/AuxiliaryKernelExtensions.kc`
  (after saving a `.pre-raphaeli` backup). Managed alternative: `sudo kmutil rebuild`.
  **Printed only; never run by the script** — no 780M on this host.
- **Kext install:** `rm -rf` old, `ditto` copy to `/Library/Extensions/Raphaeli.kext`,
  `chown -R root:wheel` (kmutil treats non-root:wheel bundles as codeless).
- **Validation:** `plutil -lint` on Info.plist, CFBundleIdentifier must be `me.tretrauit.raphaeli`,
  CFBundleExecutable must name an executable under `Contents/MacOS/`, `otool -l | LC_UUID` on
  the executable, `strings | grep -x me.tretrauit.raphaeli` for the kmod_info name. Package-time
  validation additionally requires every PCI personality to match validated device `0x15bf`.
- **Firmware:** pre-census of the 11 required blobs plus optional firmware (lists mirror `fw/stage.sh`) against
  `$REPO/firmware/amdgpu` (overridable via `RAPHAELI_FW_SRC` for tests); aborts with missing list +
  linux-firmware URL. Then `sudo mkdir -p /Library/Raphaeli/firmware`, chown root:wheel,
  `sudo sh fw/stage.sh <src> /Library/Raphaeli/firmware`.
- **KDK autodetect:** `sw_vers` → `/Library/Developer/KDKs/KDK_<productVersion>_<buildVersion>.kdk`;
  on this host resolves to `KDK_15.7.8_24G824.kdk` (installed).
- **Aux KC build:** exact proven recipe: `sudo kmutil create -a x86_64 -n aux -x -p
  /Library/Extensions/Raphaeli.kext --no-authentication -A /Library/KernelCollections/Raphaeli.auxkc
  -B /System/.../BootKernelExtensions.kc -S /System/.../SystemKernelExtensions.kc --kdk <KDK>`.
- **Boot-arg opt-in (`--apply`):** reads current `boot-args` via `nvram -p`, appends `raphaeli-amd=1`
  preserving existing args (skips if present). Prints rollback: `nvram -d raphaeli-gpu-attaching`
  (boot guard from `xnu/nmx_kext.cpp` — driver parks itself if the marker persists), `nvram -d boot-args`
  caveat, Recovery-mode `kmutil trigger-panic-medic` last resort.
- **`--uninstall`:** removes kext, `/Library/Raphaeli/firmware`, `Raphaeli.auxkc`, strips
  `raphaeli-amd=1` from boot-args (verified: preserves `-v debug=0x100 keepsyms=1 ctrsmt=full` on
  this host), clears `raphaeli-gpu-attaching`, and prints the required `sudo kmutil rebuild` follow-up
  (aux KC keeps the kext until kernelmanagerd rebuilds — per man page).
- **Dry-run (`--dry-run`):** every privileged step prints `DRY-RUN: sudo ...` instead of executing;
  non-privileged read-only steps (plutil/otool/strings/sw_vers/census) still run.
- sudo used only for privileged steps; skips sudo prefix when already root.

## Validation run

- `./install.test.sh` → 16/16 pass: help/unknown-option/dup-path/bad-path exits, full dry-run prints
  ditto + chown + stage.sh + kmutil create + auxkc path + cp apply step + boot-guard rollback, does
  not touch boot-args without `--apply`, missing-firmware census aborts with file list + fetch URL.
- `./install.sh --dry-run` validates the selected kext bundle before the firmware census; package-time target validation rejects stale vendor-wide bundles.
- shellcheck: not installed on this host (`command -v shellcheck` empty); the harness lints both
  scripts clean of the patterns I could check by eye; install shellcheck separately if wanted.

## Firmware census

`Raphaeli/firmware/amdgpu/` contains the required firmware blobs. `ip_discovery.bin` is optional
per `Raphaeli/Firmware/stage.sh` and is not part of the installer required census.

## Open risks

- Aux KC apply step (copy over AuxiliaryKernelExtensions.kc) is correct per kmutil man page +
  this host's layout, but untestable without the 780M target / a reboot.
- `--apply` could not be exercised on this host because the census gate aborts first; the nvram
  append/preserve logic was verified in the `--uninstall` dry-run path instead.
- kext sources untouched; no kext code modified.
