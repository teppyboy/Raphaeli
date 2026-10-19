# OpenCore injection: missing graphics-family superclass vtables

## Current target status

User correction: Raphaeli injection always fails on Tahoe Recovery. Recovery
UI sometimes appears; other boots reboot. Neither outcome demonstrates that
Raphaeli loaded. No successful-injection baseline, including release 1.0.3,
should be assumed without a log showing success.

The firmware-label fix c841a35 removed 28 invalid undefined symbols. It did
not resolve the reported injection failure. Earlier reports conflated a real
binary defect with a demonstrated explanation of OpenCore's vtable failure.

## Reproduction instead of kmutil inspection

Built OpenCorePkg's userspace `Utilities/TestKextInject/KextInject`:

- OpenCorePkg commit `81ecf1a` (temporary clone `/tmp/raphaeli-oc-prelink`).
- AUDK shallow checkout `/tmp/raphaeli-oc-audk`.
- `make -C /tmp/raphaeli-oc-prelink/Utilities/TestKextInject -j8 UDK_PATH=/tmp/raphaeli-oc-audk DEBUG=1`.
- Input KC: host `/System/Library/KernelCollections/BootKernelExtensions.kc`
  (Sequoia, **not** the target's Tahoe Recovery KC).
- Raphaeli input: `out-disp/Raphaeli.kext`, executable 14,297,712 bytes,
  after c841a35. No kernel load or system-volume modification performed.

Tool arguments are `KextInject <KC> <binary> <plist> [<binary> <plist> ...]`.
Run in a scratch directory: the tool writes `out.bin`. Its exit status also
reflects unrelated built-in patch tests; inspect the exact per-kext injection
result, not its aggregate exit status or final prelink-completion message.

### A: Raphaeli alone — fails

```sh
R=/Users/yuuki/Documents/tretrauit/code/Raphaeli/out-disp/Raphaeli.kext/Contents
cd /tmp
/tmp/raphaeli-oc-prelink/Utilities/TestKextInject/KextInject \
  /System/Library/KernelCollections/BootKernelExtensions.kc \
  "$R/MacOS/Raphaeli" "$R/Info.plist"
```

Result:

```text
OCAK: com.apple.iokit.IOGraphicsFamily not in Boot KC, using kernel stub for symbol-only deps
OCAK: com.apple.iokit.IOAcceleratorFamily2 not in Boot KC, using kernel stub for symbol-only deps
OCAK: Vtable patching failed for kext me.tretrauit.raphaeli
[FAIL] .../Raphaeli injected - Invalid Parameter
[OK] Prelink inject complete success
```

Instrumented only the temporary OpenCore checkout's `Vtables.c` at the
`SuperVtable == NULL` branch. It reports missing superclass vtables for
`RaphaeliFB` (`IOFramebuffer`) and every IOAccel-derived Raphaeli class,
including `RaphaeliTask` (`IOAccelTask`) and `RaphaeliAccel`
(`IOGraphicsAccelerator2`). The patcher makes no further progress and fails.

Source evidence:

- `PrelinkedKext.c: InternalCachedPrelinkedKext` aliases an absent dependency
  to the kernel's Mach-O context. The source explicitly says this stub has no
  vtable source and **cannot satisfy subclassing**.
- `Vtables.c: InternalPatchByVtables` skips classes whose superclass vtable
  is unavailable, then returns false when an iteration patches no classes.
- `Link.c` reports `Vtable patching failed` when that function returns false.

Removing OSBundleLibraries entries cannot supply these superclass vtables.
Skipping this safety check or replacing unresolved symbols with dummy values
would not be a valid fix.

### B: Matching Sequoia graphics families before Raphaeli — passes

```sh
K=/Library/Developer/KDKs/KDK_15.7.8_24G824.kdk/System/Library/Extensions
/tmp/raphaeli-oc-prelink/Utilities/TestKextInject/KextInject \
  /System/Library/KernelCollections/BootKernelExtensions.kc \
  "$K/IOGraphicsFamily.kext/IOGraphicsFamily" "$K/IOGraphicsFamily.kext/Info.plist" \
  "$K/IOAcceleratorFamily2.kext/Contents/MacOS/IOAcceleratorFamily2" \
  "$K/IOAcceleratorFamily2.kext/Contents/Info.plist" \
  "$R/MacOS/Raphaeli" "$R/Info.plist"
```

All three per-kext injection results are `Success`. IOGraphicsFamily v599;
IOAcceleratorFamily2 v485. Logs: `/tmp/raphaeli-oc-deps.log`.

### C: Tahoe 26.6 KDK graphics families — prelink-only experiment passes

Downloaded Dortania KdkSupportPkg release `25G72`:

`https://github.com/dortania/KdkSupportPkg/releases/download/25G72/Kernel_Debug_Kit_26.6_build_25G72.dmg`

SHA-256 verified against release `SHA256SUM`:

`3bc885798d29a51965e9fc7c38090cfb20aa9b19d51b4e6f0175caf9e7b04819`

Mounted read-only, expanded using `pkgutil --expand-full`; did **not** install
it on the host. Payload root:
`/tmp/raphaeli-kdk-26.6-expanded/KDK.pkg/Payload`.

Repeated B using its graphics binaries/plists:

| Family | CFBundleVersion | OSBundleCompatibleVersion |
| --- | --- | --- |
| IOGraphicsFamily | 600 | 1.0.0b1 |
| IOAcceleratorFamily2 | 487.4.3 | 2.0.0 |

All three per-kext injection results are `Success`.
Log: `/tmp/raphaeli-oc-tahoe-deps.log`.

**This uses the Sequoia host KC with Tahoe dependencies solely to inspect the
linker. It is NOT a supported cross-version runtime configuration or a Tahoe
Recovery validation. Never distribute/deploy this mixed collection.**

## SDK versus KDK

The build scripts already select `xcrun --sdk macosx`; installed Xcode reports
macOS SDK **26.2**. The earlier claim that these scripts necessarily compile
against Sequoia public kernel headers was incorrect. The deployment minimum
`-mmacosx-version-min=15.0` does not select an SDK or provide dependency vtables.

The installed `KDK_27.0_26A5368g.kdk` is not Tahoe 26.6. The downloaded Tahoe
26.6 KDK's SDK payload also contains only supplemental platform headers, not
a complete replacement for Xcode's public Kernel.framework headers. Private
IOAccel declarations in Raphaeli still come from the reconstructed research
headers; a KDK switch alone does not regenerate those declarations.

## Repeatable repository gate

`scripts/check-oc-injection.sh` wraps the built OpenCore utility without
modifying system files. Example:

```sh
./scripts/check-oc-injection.sh \
  /tmp/raphaeli-oc-prelink/Utilities/TestKextInject/KextInject \
  /System/Library/KernelCollections/BootKernelExtensions.kc \
  /tmp/new-oc-injection-run \
  out-disp/Raphaeli.kext/Contents/MacOS/Raphaeli \
  out-disp/Raphaeli.kext/Contents/Info.plist
```

Append dependency binary/plist pairs **before** Raphaeli to check dependency
injection. A new scratch directory is mandatory. The wrapper converts relative
inputs to absolute paths, captures the log and tool output there, and requires
an exact successful injection message for **every** binary plus completion.
It rejects missing results, failed dependencies, zero-valued relocation symbols,
vtable failures, and abnormal tool termination. Exit 255 alone is not fatal:
OpenCore's bundled unrelated quirk tests also set that status. Explicit per-kext
results are authoritative for this gate, not runtime load/attach.

Verified wrapper against real OpenCore: Raphaeli alone exits 1, matching host
families plus Raphaeli exits 0. Fixture tests under `/bin/bash` 3.2 cover
relative/spaced paths, unrelated-quirk exit 255, omitted/failed injection,
failed dependency with successful Raphaeli, unresolved-symbol warnings, missing
completion, crash status, and scratch overwrite refusal.

Repository validation after adding the gate and collector: `build.sh` 900/900;
`rt.sh` 81/81; relink unchanged SHA-256 prefix `39a7f97f`; `kmutil inspect`
exit 0 (sanity only). Firmware-bundle, install (16/16), oc-install, EDID,
collector, and prelink-wrapper tests pass. `bash -n` and `git diff --check`
pass. Active shell LSP probes were inconclusive, not proof of clean diagnostics.

## Next target-specific step

Obtain the actual Recovery `SystemVersion.plist` (ProductVersion and
ProductBuildVersion), its `BootKernelExtensions.kc`, and the latest OC failure
block. SDK version in boot.efi metadata alone does not establish the exact OS
build. Test against that KC before selecting dependency binaries.

OpenCore's documented `Kernel > Force` loads uncached dependencies from the
booted system volume before `Kernel > Add`. It is a candidate if that Recovery
image actually includes the matching executable kexts. Some system bundles
have plists but no standalone executables; verify files first. Otherwise a
matching-build KDK or target System KC extraction is needed. Do not inject
Sequoia families into Tahoe, remove graphics support in Recovery, or ship an
unverified cross-build replacement. The staging experiment now places the
validated dependency bundles inside `Raphaeli.kext/Contents/PlugIns/` and
references those nested paths explicitly; runtime acceptance still requires a
real OpenCore prelink result against the target KC.

The intermittent reboot remains unexplained: capture panic evidence. OC
injection failure occurs before Raphaeli entry/start, so do not diagnose a
Raphaeli runtime fault from this log alone.
