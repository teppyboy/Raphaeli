# OC prelinked injection of Raphaeli.kext fails: Invalid Parameter

> Superseded diagnosis: local OpenCore userspace reproduction now shows missing
> graphics-family superclass vtables are fatal, not benign. The dependency-version
> changes below did not establish target injection success. The target boots
> Tahoe Recovery, not the Sequoia version assumed below. See
> [OC vtable reproduction](oc-vtable-reproduction.md) for evidence and remaining
> target-specific validation. Do not use this historical report as proof of a fix.

Symptom (target 780M machine, OpenCore verbose boot):

```text
OCAK: com.apple.iokit.IOGraphicsFamily not in Boot KC, using kernel stub for symbol-only deps
OCAK: com.apple.iokit.IOAcceleratorFamily2 not in Boot KC, using kernel stub for symbol-only deps
OCAK: Vtable patching failed for kext me.tretrauit.raphaeli
OC: Prelinked injection Raphaeli.kext (Raphaeli 780M (me.tretrauit.raphaeli) - inert until raphaeli-amd=1) - Invalid Parameter
```

## Root cause (ranked)

### 1. OSBundleLibraries versions exceed the families' compatible versions — FIXED

`Raphaeli/Info.plist` requested dependency versions the families never offer:

| dependency | requested | available (KDK 15.7.8_24G824, `OSBundleCompatibleVersion`) |
|---|---|---|
| com.apple.iokit.IOPCIFamily | `1.0.0` | `1.0.0b1` |
| com.apple.iokit.IOACPIFamily | `1.0.0` | `1.0.0d1` |
| com.apple.iokit.IOGraphicsFamily | `1.0.0` | `1.0.0b1` |
| com.apple.iokit.IOAcceleratorFamily2 | `2.0.0` | `2.0.0` (OK) |

Apple version ordering treats `b1`/`d1` as pre-release, so `1.0.0b1 < 1.0.0`: the
request cannot be satisfied. OC prelinked injection resolves every
OSBundleLibraries entry against the boot KC before linking; an unresolvable
version makes the prelink fail with `Invalid Parameter` (the later
"Prelinked injection Raphaeli.kext v1.0.0" line is just the generic
announcement, not a success). Reference: NootedRed declares
`com.apple.iokit.IOPCIFamily 1.0.0b1`; every shipped Apple kext declaring these
families uses the `b1`/`d1` forms.

Fix: request `1.0.0b1` / `1.0.0d1` / `1.0.0b1` (all confirmed against the KDK
plists). kpi.* entries (`8.0`) are satisfiable and unchanged. Deps stay minimal:
binary needs IOPCIFamily (IOPCIDevice), IOACPIFamily
(`IOACPIPlatformDevice::gMetaClass`), IOGraphicsFamily (IOFramebuffer subclass),
IOAcceleratorFamily2 (IOAccelTask/IOGraphicsAccelerator2 subclass) — all four
required, nothing to drop.

This also explains why dev-host `kmutil create` passed: the dev host resolves
from the KDK stubs on disk with lenient version handling, while OC prelink is
strict against the KC.

### 2. "Vtable patching failed" — benign consequence of the stub path

OCAK vtable patching is the prelink-side vtable adjust for kexts inheriting KC
classes when OC uses kernel stubs (message (a) shows it took the stub path).
With injection itself failing at dependency resolution the patch pass cannot
complete; it is a downstream symptom, not an independent cause. Our class vtable
layout comes from the KDK 15.7.8_24G824 (build 24G824) headers, which match a
15.7.x (24Gxxx) boot KC on the target. Verdict: no local fix; re-check only if
the injection succeeds on a target running an older build (e.g. Sonoma 23.x,
below MinKernel 23.4.0-adjacent KDK mismatch) and vtable warnings persist
without load — then rebuild against that build's KDK.

### 3. Config.plist entry mismatch — rule out with the checklist below

`Invalid Parameter` can also come from OC failing to open the bundle files.
Entry was verified consistent with oc-install.py output, but verify on the
target anyway (see checklist).

## User checklist (target machine)

1. config.plist `Kernel > Add` entry must be exactly:
   - `Arch`: `x86_64`
   - `BundlePath`: `Raphaeli.kext`
   - `Comment`: `Raphaeli.kext` (any text is fine; was the verbose string)
   - `Enabled`: `true`
   - `ExecutablePath`: `Contents/MacOS/Raphaeli`
   - `MaxKernel`: `` (empty)
   - `MinKernel`: `23.4.0`
   - `PlistPath`: `Contents/Info.plist`
2. `EFI/OC/Kexts/Raphaeli.kext/` must exist with `Contents/Info.plist` and
   `Contents/MacOS/Raphaeli` (dist zip layout: `kext/Raphaeli.kext`).
3. The staged kext must be the FIXED build (this fix): re-run
   `python3 tools/oc-install.py <EFI> --add` from a dist zip packaged after
   this change, or stage the dev-tree bundle directly:
   `RAPHAELI_KEXT=out/Raphaeli.kext python3 scripts/oc-install.py <EFI> --add`.
   `--add` now also refreshes the Comment of an existing entry.
4. OC boot: `Kernel > Quirks > AppleXcpmCfgLock`/secure-boot model per
   install-flow.md; kext injection needs `SecureBootModel` not blocking it and
   `Kernel > Add` entry Enabled (check `--status`).
5. boot-args: kext stays inert until `raphaeli-amd=1` (`--enable`). For first
   bring-up attach: verbose (`-v`) + `raphaeli-amd=1`; abort with `--disable`,
   `Enabled=false`, or `-nvoff`.

## Changes made

- `Raphaeli/Info.plist`: OSBundleLibraries versions `1.0.0` → `1.0.0b1`
  (IOPCIFamily), `1.0.0d1` (IOACPIFamily), `1.0.0b1` (IOGraphicsFamily) +
  comment. `out/Raphaeli.kext/Contents/Info.plist` refreshed (plain copy, no
  rebuild).
- `scripts/oc-install.py`: new entries get `Comment: Raphaeli.kext`; existing
  entries with the old verbose comment are refreshed on `--add`.
- `scripts/oc-install.test.sh`: all pass after the change.

## Residual

- Published dist zips (up to 1.0.2) still contain the old plist — repackage
  before shipping (release decision, not done here).
- If Invalid Parameter persists after re-staging the fixed kext with a verified
  config entry, next suspects: OC version-specific prelink bug (try OC 1.0.5+)
  and the stub path's vtable adjust — capture the full OCAK block again.
