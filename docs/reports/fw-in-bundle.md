# Firmware embedded in the kext bundle (self-contained lane)

Lane: firmware-in-bundle (owns `Raphaeli/Kernel/nmx_platform.cpp`, `scripts/link.sh`, `scripts/fw-bundle.test.sh`; did not touch package.sh / install.sh / oc-install.py / recovery-install.sh, nmx_fb*/nmx_accel*/dm bridge).

## Goal

OC injection alone fully equips the driver with firmware: no `/Library/Raphaeli/firmware` staging, no post-install scripts. The kext must boot-attach (no 300 s wait for a firmware folder that never comes) and drive the Phoenix GPU from blobs it carries itself.

## Why the plan's Resources-dir read was replaced with link-embedded blobs

The plan proposed resolving the kext's own `Contents/Resources/firmware/amdgpu/` through `OSKext`. Verified against the Sequoia Kernel.framework headers (the KDK 15.7.8 ships no kernel API headers, only platform fragments; the SDK is the source of truth):

- kernel `OSKext` has **no** `getCurrentKext()`, **no** `getBundleURL`/`resourcesURL`/`copyResourceURL`. Available: `lookupKextWithIdentifier/WithLoadTag`, `getLoadTag`, `copyUserExecutablePath` (DriverKit dexts only — no disk path is retained for a kext injected by OC prelink or auxKC; the kernelcache embeds executable + Info.plist, never `Resources`).
- Therefore kernel-side VFS access to the bundle's Resources directory is **not implementable** for this load path.

Approved alternative (supervisor sign-off, matches the NootRX/GenerateFirmware.py pattern): the blobs are **linked into the Mach-O** as data, and `Contents/Resources/firmware/amdgpu/` is still populated for inspection/tooling (a recovery installer can copy from there instead of re-downloading).

## Mechanism

- `scripts/link.sh` generates, from `firmware/amdgpu/*.bin` (zero-code per added blob):
  - `xnuobj/fwgen/nmx_firmware_blobs.S` — one `.incbin` per blob with kmod-unique symbols `_nmx_fw_<blobname>_start/_end` (section `__TEXT,__const`, 16-byte aligned);
  - `xnuobj/fwgen/nmx_firmware_table.cpp` — the table `nmx_firmware_table[]` + `nmx_firmware_count` consumed by `nmx_platform.cpp`.
- `Raphaeli/Kernel/nmx_platform.cpp` resolution order:
  1. `FIRMWARE_ROOT` = `/Library/Raphaeli/firmware/` still wins (firmware can be updated by staging without relinking) — same vnode reader, refactored into `fw_read_file()`.
  2. Embedded table: logs `firmware <name>: from embedded image` and returns a heap copy (the image is read-only; the caller frees through `nmx_xnu_firmware_free`).
  3. Neither: `firmware <name>: not found (checked /Library/Raphaeli/firmware/ and the embedded image)` — both sources named.
- `nmx_xnu_wait_firmware_root` returns immediately when `nmx_firmware_count > 0` (self-contained kext never blocks attach on external staging; the 300 s wait remains for a firmware-free build).
- `link.sh` fails hard if any blob in the `REQUIRED` census of `Raphaeli/Firmware/stage.sh` (single source of truth, parsed, not duplicated) is absent from `firmware/amdgpu/`.

## Kernel-side numbers

- Phoenix set staged: **14 blobs, 3,308,640 B (3.16 MiB)** — under the ~8 MB budget.
- Binary size: 10,977,304 B → **14,299,248 B (+3,321,944 B ≈ +3.17 MiB)**; plus a mirror copy in `Contents/Resources/firmware/amdgpu/` (bundle total grows ≈ 6.3 MiB with the Resources copy).
- Required census: all 11 required Phoenix blobs resolve from the bundle (Resources + embedded symbols) — `scripts/fw-bundle.test.sh out-disp` passes.

## Validation

- `scripts/build.sh`: 900/900 sources, 0 failed. `scripts/rt.sh`: 81 runtime sources, 0 failed.
- `scripts/link.sh out-disp`: links clean; `nm` shows `_nmx_firmware_table`/`_nmx_firmware_count` defined, 0 undefined `nmx_firmware` symbols. (Caught during the lane: `const` definitions inside `extern "C"` have internal linkage in C++ — the first table object emitted nothing and would have failed at kxld load; the generator now writes `extern const`.)
- `scripts/fw-bundle.test.sh out-disp`: all 11 required blobs present as Resources files and as `_nmx_fw_*` symbols.
- `kmutil inspect -V tb -p out-disp/Raphaeli.kext`: rc=0, no errors reported for the bundle. Note: kmutil classifies kexts not owned by root:wheel as codeless and silently omits them from the listing; the auxKC build recipe (chown root:wheel, then `kmutil create`) is unchanged by this lane — Resources do not participate in the kernelcache, which is exactly why the blobs are also linked into the binary.
- `Info.plist` needed no firmware keys.

## What packaging must change next

- `scripts/package.sh` (another lane): the dist zip's `firmware/amdgpu/` directory becomes **optional for the OC route** — `oc-install.py` no longer needs to stage `/Library/Raphaeli/firmware`; keeping the dir is still useful for the manual/install.sh route and for recovery (copy from bundle Resources instead of re-downloading). The dist zip grows ≈ 3.1 MiB.
- `scripts/install.sh` / `recovery-install.sh`: can treat a missing `/Library/Raphaeli/firmware` as non-fatal when the kext bundle itself carries the census (check via `nm _nmx_fw_` symbols or the Resources copy).
- `Raphaeli/Firmware/README.md`: document that the kext resolves FIRMWARE_ROOT first, embedded blobs second.
