# Exact Tahoe Recovery injection reproduction

## Image acquisition and identity

Used OpenCorePkg `Utilities/macrecovery/macrecovery.py`:

```sh
python3 macrecovery.py -b Mac-CFF7D910A743CAAF -m 00000000000000000 \
  -os latest -o /tmp/raphaeli-tahoe-recovery download
```

Apple product `140-93589`, image 960,530,321 bytes. Initial transfer stalled;
resumed with a fresh macrecovery AssetToken and validated Content-Range, then
ran macrecovery's complete signed chunklist/image verifier. Signature and all
92 chunk hashes passed. No TLS verification bypass used. Apple's macrecovery
endpoint itself uses HTTP; authenticity was checked via signed chunklist.

SHA-256:
`edddd0d5869caaa12e29e6996a04f11590280580976a119dbd42c24fa62fe18e`

**Exactly matches the DMG digest in the user's original OpenCore log.** No
user upload is needed to reproduce that image. Read-only mount reveals:

- ProductVersion: **26.6.2**.
- ProductBuildVersion: **25G83**.
- BootKernelExtensions.kc: 67,584,000 bytes.
- BaseSystemKernelExtensions.kc: 22,282,240 bytes.

Previous inference "26.6" from the booter's SDK metadata did not identify the
actual Recovery patch version. Corrected by inspecting SystemVersion.plist.

## Scope and ABI boundary

This exact 26.6.2 / 25G83 image validates Recovery/KDK dependency injection
behavior only. It does **not** validate the private accelerator forwarding ABI;
the available forwarding source is from 26.7.1. Tahoe source, runtime, and link
builds therefore remain intentionally blocked. Do not set `tahoe_target_validated=yes`
or treat this prelink experiment as a Tahoe build success.

## Where the families really live

`kmutil inspect -B <Recovery Boot KC> -S <Recovery BaseSystem KC>
--show-kext-uuids` reports:

| Module | Collection | Version | x86_64 UUID |
| --- | --- | --- | --- |
| IOReportFamily | Boot | 47 | not needed for this experiment |
| IOSurface | Boot | 393.5.8 | not needed for this experiment |
| IOGraphicsFamily | BaseSystem | 600 | 74AA6483-8AB4-3A94-8143-5E306C16D7DA |
| IOAcceleratorFamily2 | BaseSystem | 487.4.3 | B77A42EC-6B0C-3A8D-89A2-B8F4CDBAC8C9 |

Standalone IOGraphicsFamily binary exists on the image; IOAcceleratorFamily2
has a plist but no standalone executable. Thus `Kernel > Force` alone cannot
obtain both dependencies from this image's filesystem.

## Exact-build KDK and prelink test

Downloaded and checksum-verified KdkSupportPkg release `25G83`:

`https://github.com/dortania/KdkSupportPkg/releases/download/25G83/Kernel_Debug_Kit_26.6.2_build_25G83.dmg`

SHA-256: `577cdc8b2c09eaebfb16b0372ab6d6dc128ad4a08eaae09428d84a6c8a1e53c3`.

Read-only mount + `pkgutil --expand-full`; never ran installer. Extracted
payload `/tmp/raphaeli-kdk25G83-expanded/KDK.pkg/Payload`. Its SystemVersion
build and both family UUIDs/versions match the image exactly.

Real OC prelink tests against **this exact Recovery Boot KC**:

1. Raphaeli alone: **FAIL**, same missing superclass vtables and
   `Vtable patching failed` / `Invalid Parameter`.
   Log `/tmp/raphaeli-target-exact-alone/injection.log`.
2. KDK 25G83 IOGraphicsFamily, then IOAcceleratorFamily2, then Raphaeli:
   **PASS for all three**. No zero-valued relocation warning.
   Log `/tmp/raphaeli-target-exact-deps-25G83/injection.log`.

The 25G72 KDK copies also have identical family UUIDs, but the staged tool
requires the actual Recovery/KDK build to match rather than assuming this.

## Opt-in staging experiment

`scripts/oc-stage-graphics.py` runs on a macOS host. Default dry-run:

```sh
python3 scripts/oc-stage-graphics.py /Volumes/EFI \
  "/Volumes/macOS Base System" \
  /tmp/raphaeli-kdk25G83-expanded/KDK.pkg/Payload
```

`--apply` explicitly opts into writing EFI (not the system volume):

- Requires one enabled Raphaeli entry and no existing/conflicting family entry.
- Verifies Recovery/KDK build, x86_64 family UUIDs against the Recovery KCs,
  and CFBundleVersion against their metadata.
- Stages dependency bundles inside `EFI/OC/Kexts/Raphaeli.kext/Contents/PlugIns/`.
- Inserts IOGraphicsFamily then IOAcceleratorFamily2 immediately before Raphaeli.
- Restricts new entries to the tested Darwin minor (25.6.0–25.6.99).
- Creates a unique original-config backup before atomically updating config.
- Refuses overwrite; failed copy/config replacement leaves original config intact
  and cleans newly staged dependency directories.
- Leaves boot args, NVRAM, other entries, and driver Recovery attachment intact.

Rollback: restore the printed config backup, then remove the newly staged
`Raphaeli.kext/Contents/PlugIns/` directory. Revalidate after **any** OS/Recovery update;
Darwin minor constraints cannot distinguish every patch build.

Normalized bundles staged by the tool also pass the real OC gate against the
exact Recovery Boot KC (`/tmp/raphaeli-target-normalized-deps/injection.log`).
No kernel code changed: latest full kernel/runtime checks remain 900/900 and
81/81, with identical `39a7f97f` kext. Existing OC installer, prelink wrapper,
and Recovery collector tests pass; `bash -n` and `git diff --check` pass.
Active LSP probe was inconclusive, not a clean-diagnostics assertion.

Verification: 8 unittest fixtures cover flat/Contents bundle conversion,
ordering, unchanged NVRAM, backup fidelity, existing-entry refusal, build/UUID/
version mismatch, copy failure, and config replacement rollback. Actual dry-run
and apply exercised only in `/tmp/raphaeli-exact-staging*`, never real EFI.

## Full OpenCore configuration processing

Built OpenCorePkg `Utilities/ocvalidate` and `Utilities/TestProcessKernel` at
`81ecf1a`, with AUDK headers and DEBUG userspace libraries. Generated the
sample 1.0.9 config with staged entries and the current Raphaeli bundle in a
temporary EFI directory (`/tmp/raphaeli-exact-staging/EFI/OC`).

- `ocvalidate <temp-OC>/config.plist`: exit 0, no issues.
- `ProcessKernel <temp-OC>/ <exact-Recovery-BootKC>`: exit 0.
- Logs explicitly report injection `Success` for IOGraphicsFamily,
  IOAcceleratorFamily2, and Raphaeli, in that order; prelinked status Success.
- Scratch output/log: `/tmp/raphaeli-full-process-72/`.

This exercises config parsing, executable-path resolution, reservation, kernel
version matching, ordered injection and full prelink completion, not just the
standalone kext injection API. It still does not boot a kernel, load the second
KC, or validate the user's other OC patches/personality configuration.

## What remains unproven

This is an **injection-tested experiment**, not a production-ready fix or GPU
acceleration. The BaseSystem KC also contains copies of the Apple families;
XNU's duplicate-ID registration logic prefers an existing loaded/prelinked copy,
but it does not prove all direct cross-KC relocations are safe when the same
modules are additionally injected into Boot KC. Actual target boot/panel tests
are mandatory. Do not automatically apply this or distribute Apple binaries
as a universal dependency package.

No speculative guessed vtable offsets, dependency removal, OC patch-safety
bypass, or Recovery opt-out was introduced. Reboot cause remains unknown until
there is target panic evidence. GPU VM/submit implementation is still incomplete.
