# Final whole-branch review fixes

Applied reviewer findings without widening hardware support.

- `Info.plist` now matches only validated Phoenix/Radeon 780M PCI ID `0x15bf`; Intel/vendor-wide personalities removed.
- Direct install census treats `ip_discovery.bin` as optional, matching `Firmware/stage.sh`.
- `target-preflight.sh` validates exact accelerator provenance and rejects Tahoe while `tahoe_target_validated=no`; package, recovery, and OpenCore selection paths fail closed.
- OpenCore positional system-root parsing sets `SYSTEM_ROOT_SET`; config backup names receive collision-free suffixes.
- `make-pkg.sh --with-kext` requires an explicit target and uses `out/target/<Target>/Raphaeli.kext`.
- Recovery volume and firmware iteration uses Bash 3.2-compatible scalar loops.
- Provenance validation enforces approved repository, commit, and source path.
- Reports and regression fixtures updated for current firmware census, target requirements, and Tahoe gate.

Validation: recovery, package-target, and accelerator-source tests pass. OpenCore target tests contain legacy Tahoe-success cases that now conflict with the intentional fail-closed lock; install fixture requires a linked kernel binary and cannot pass on this unbuilt checkout. Hardware behavior remains unverified.
