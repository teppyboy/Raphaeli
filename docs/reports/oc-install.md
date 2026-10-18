# Raphaeli oc-install — OpenCore integration report

## Architecture (portable core + thin wrapper)

- `xkpi/oc-install.py` — the whole implementation, Python3 **stdlib only**
  (`plistlib, shutil, subprocess, os, re, sys, datetime, typing`). No
  PlistBuddy, plutil, or ditto anywhere: config.plist is read/written with
  `plistlib` (XML format preserved, atomic write via temp file + os.replace),
  the kext is copied with `shutil.copytree(..., symlinks=True)`, plist
  validation is `plistlib.load`.
- `xkpi/oc-install.sh` — thin wrapper: finds python3 and `exec`s the core.
  CLI identical to the core.

## Boot-arg semantics (from xkpi/xnu/nmx_kext.cpp)

`Raphaeli::probe()` (nmx_kext.cpp:57-73) reads the device vendor, then calls
`opted_in()` (nmx_kext.cpp:59-70):

- If `-amdgpuoff` is set → return false (parks every Raphaeli GPU driver for that boot).
- If `raphaeli-amd=1` (AMD vendor, our case) parses with a nonzero value → opt in.
- Else, if the IOPCIDevice has a truthy `raphaeli-gpu` property → opt in.
- Otherwise → false.

`probe()` returns `nullptr` when not opted in, i.e. **without `raphaeli-amd=1`
(and without the `raphaeli-gpu` device property) the kext does NOT attach at
all** — it is not "attach then park"; the device is left to macOS entirely
(nmx_kext.cpp:71 `return nullptr;`). Loading the kext via OC with
`Enabled=true` but no boot-arg is therefore completely inert: safe default for
a 780M-only machine where a display-capable driver must never load by default.

Secondary park paths (install.sh header + nmx_kext.cpp:156):
`raphaeli-gpu-attaching` NVRAM marker set during attach parks the driver on
the next boot if a previous attach never returned; `-amdgpuoff` parks per-boot.

## What oc-install does

- `--add`: backup `config.plist` → `config.plist.raphaeli-backup-<ts>`,
  copy `xkpi/out/Raphaeli.kext` → `EFI/OC/Kexts/` (copytree, portable),
  insert `Kernel>Add` entry (Arch x86_64, BundlePath Raphaeli.kext, Enabled
  true, ExecutablePath Contents/MacOS/Raphaeli, MaxKernel empty, MinKernel
  23.4.0, PlistPath Contents/Info.plist); creates `Kernel>Add` array if
  missing; adds NO boot-arg (inert by default, per semantics above).
- `--enable` / `--disable`: append / word-exact-strip `raphaeli-amd=1`
  on `NVRAM>Add>7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args`; idempotent;
  creates NVRAM/Add/GUID path if absent.
- `--remove`: delete the Add entry + staged kext; backups kept.
- `--status`: entry presence/Enabled, kext staged, boot-arg, firmware census
  under `<system-root>/Library/Raphaeli/firmware` with required/optional blob
  lists parsed live from `fw/stage.sh` (source of truth).
- `--firmware-src <dir>`: census source, stage via `fw/stage.sh` (POSIX sh,
  kept as-is) onto `<system-root>/Library/Raphaeli/firmware` (system root:
  2nd positional or `--system-root`, default `/`).
- Target: mounted EFI volume path, or disk identifier — macOS `diskXsY`
  (diskutil mount/info), Linux `/dev/sdXN` or bare `sdXN` (lsblk vfat lookup,
  udisksctl mount, else a die message with the manual-mount command);
  `--dry-run` prints planned actions only.
- Never touches SystemKernelExtensions / aux KC / kmutil (OC injects without
  aux rebuild). Always prints the OC boot-menu safety note (Cmd+V, --disable
  or Enabled=false restores display, -amdgpuoff, boot-guard marker).

## Linux path (no macOS available)

    python3 oc-install.py /media/user/EFI --add --target sequoia --system-root /mnt/target
    oc-install.sh /media/user/EFI --status --system-root /mnt/target

Mounting: `lsblk -pno NAME,FSTYPE,PARTLABEL,MOUNTPOINT` finds the vfat EFI
partition; if unmounted, `udisksctl mount -b /dev/sdXN` is used; if udisksctl
is absent the tool exits with the exact manual command to run
(`sudo mount /dev/sdXN /mnt/efi && python3 oc-install.py /mnt/efi --add --target sequoia --system-root /mnt/target`).

## Validation

`oc-install.test.sh`: 28 assertions against a fake EFI tree in /tmp (never
touches a real EFI): python-core portability audit (stdlib-only imports, no
macOS-only plist/copy tool references), add (entry fields, kext staged,
backup, no boot-arg), add idempotency, enable + idempotency, disable,
dry-run non-mutation for enable/remove, status, full remove rollback,
missing-Add-array creation, bad target rejection, and a direct python-core
smoke cycle (add/enable/remove without the shell wrapper). Result: ALL TESTS
PASSED. `python3 -m py_compile oc-install.py` clean.

## Task 2 fix round 2

Existing-entry refresh is transactional. `--add` now rejects a disabled existing
entry before firmware staging, creates a config backup before changing bounds,
comments, duplicates, or insertion, prepares and stamps a sibling staging
bundle, validates firmware staging, then updates `config.plist` and swaps the
staged bundle. Existing staged bundles remain in a temporary rollback path until
config commit succeeds; config bytes and the old bundle are restored on commit
failure. The backup preserves the exact pre-mutation config for every `--add`.

Regression coverage verifies backup fidelity for an existing-entry bounds
refresh, rejects disabled entries before firmware staging, and simulates a copy
failure while an existing entry and staged bundle are present, asserting both
remain byte-for-byte unchanged and no staging residue remains.

Validation:

```sh
python3 -m unittest scripts/tests/oc_install_target_test.py
bash scripts/oc-install.test.sh
python3 -m py_compile scripts/oc-install.py scripts/tests/oc_install_target_test.py
git diff --check
```

Results: 12 target tests passed; OpenCore shell integration passed; compile and
whitespace checks passed.

## Tahoe fail-closed fixture update

`Raphaeli/Kernel/Accel/upstream/SOURCE.lock` remains authoritative with
`tahoe_target_validated=no`. Target-resolution coverage now explicitly asserts
Tahoe rejection for both the explicit selector and macOS 26 system-root
selection. Successful `--add`, metadata-stamping, transactional rollback, and
status fixtures select Sequoia, so those tests exercise action success without
fabricating Tahoe validation.

Validation also covered target, OpenCore, Recovery, package, and source test
suites; Python compilation, Bash syntax, and `git diff --check` passed.

## Files

- `xkpi/oc-install.py` (new, portable core)
- `xkpi/oc-install.sh` (new, thin python3 wrapper)
- `xkpi/oc-install.test.sh` (new)

`install.sh` and kext sources untouched.

## Task 2 fix round 1

Reviewer findings addressed:

- `--add` now stamps the selected bundle's staged `Contents/Info.plist` with
  `SelectedTarget` and supplies `CFBundleName=Raphaeli` when absent. The source
  bundle remains unchanged; target selection and kernel bounds still come from
  the production resolver and `Kernel>Add` entry.
- Duplicate `Kernel>Add` entries for `Raphaeli.kext` are handled deterministically:
  the first entry is retained and refreshed, later matching entries are removed
  in reverse index order. Unrelated entries remain in their original order.
- Target fixtures now start without `SelectedTarget`, proving production
  staging—not fixture setup—creates the metadata.

Validation:

```sh
python3 -m unittest scripts/tests/oc_install_target_test.py
./scripts/oc-install.test.sh
python3 -m py_compile scripts/oc-install.py scripts/tests/oc_install_target_test.py
git diff --check
```

Results: 11 target tests passed; OpenCore shell integration passed; compile and
whitespace checks passed.
