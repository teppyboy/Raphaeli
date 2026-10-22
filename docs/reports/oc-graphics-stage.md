# OC graphics dependency staging (Sequoia 15.7.8 / 24G824)

Tool: `scripts/oc-stage-graphics.py` (macOS host). Test: `scripts/oc-stage-graphics.test.sh`.

## Evidence (host, 15.7.8 24G824)

- Recovery/target build for this lane: Sequoia 15.7.8 `24G824`.
- KDK `/Library/Developer/KDKs/KDK_15.7.8_24G824.kdk`: ProductBuildVersion `24G824`,
  Darwin Kernel Version `24.6.0`.
- KDK `IOGraphicsFamily.kext` (flat layout, no `Contents/`): `CFBundleVersion` 599,
  `OSBundleCompatibleVersion` 1.0.0b1, x86_64 UUID `CA8B49BC-3655-312C-91AA-FB848251C78E`.
- KDK `IOAcceleratorFamily2.kext`: `CFBundleVersion` 485, `OSBundleCompatibleVersion` 2.0.0,
  x86_64 UUID `65CEB805-D326-3F15-9595-F6EC0A6D78DA`.
- Host `BootKernelExtensions.kc` (`kmutil inspect --show-kext-uuids`): the same two
  families at 485 and 599 with identical UUIDs. The host KC is Sequoia, so it is the
  matching BootKC for this KDK.
- Not present on host: a Sequoia BaseSystem image. Preflight therefore cannot be
  run end to end against a real Recovery volume here.

## Behavior

- Requires Recovery and KDK `ProductVersion` to start with `15.`. Tahoe (26.x)
  Recovery or KDK is rejected before any binary is read, so Tahoe binaries never
  mix with a Sequoia BootKC.
- Requires equal `ProductBuildVersion` for Recovery and KDK.
- Requires the Recovery BootKC/BaseSystemKC UUID and version to match each KDK
  family binary and plist (UUID and `CFBundleVersion`).
- Default is dry run. `--apply` writes `EFI/OC/Kexts/RaphaeliDependencies/`
  and inserts the two family entries ahead of `Raphaeli.kext` (`MinKernel` /
  `MaxKernel` = the exact Darwin minor). Raphaeli's own entry and `boot-args`
  are not changed, so the driver stays inert.
- Refuses if `RaphaeliDependencies` already exists or a family entry is present.
- Rollback: restore `config.plist.raphaeli-graphics-backup-*` and remove
  `EFI/OC/Kexts/RaphaeliDependencies`.

## Not automatic

- Staging is explicit: the user supplies the EFI, Recovery root, and KDK paths.
  The tool does not download or select a KDK by itself.
- Hardware injection and runtime load on the target remain unverified.

## Command

```sh
# dry run (default): validates everything, changes nothing
python3 scripts/oc-stage-graphics.py /Volumes/EFI "/Volumes/macOS Base System" \
  /Library/Developer/KDKs/KDK_15.7.8_24G824.kdk
# apply after reviewing the dry-run output
python3 scripts/oc-stage-graphics.py /Volumes/EFI "/Volumes/macOS Base System" \
  /Library/Developer/KDKs/KDK_15.7.8_24G824.kdk --apply
```

Pass the `KDK_*.kdk` directory (it contains `System/Library/CoreServices/SystemVersion.plist`).
