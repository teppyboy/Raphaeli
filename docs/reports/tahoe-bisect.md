# Tahoe recovery prelink regression: bisect 02e386e → 795067e

> Correction: the user subsequently confirmed injection always fails; Recovery
> UI visibility was mistaken for a successful load. c841a35 fixes real dangling
> firmware symbols, but is NOT the complete injection fix. The three new family
> symbols were not proven safe by the old build. See
> [OC vtable reproduction](oc-vtable-reproduction.md) for the reproduced
> missing-superclass-vtable failure and controlled dependency-injection tests.

Symptom (macOS 26.6 Tahoe RecoveryOS, user log; plist byte-identical to the
working 02e386e build):

```text
OCAK: com.apple.iokit.IOAcceleratorFamily2 not in Boot KC, using kernel stub for symbol-only deps
OCAK: (same for IOGraphicsFamily)
OCAK: Vtable patching failed for kext me.tretrauit.raphaeli
OC: Prelinked injection Raphaeli.kext - Invalid Parameter
```

Method: rebuilt the kext at 02e386e (worktree `research/`-era layout:
freebsd-src pinned 169e254b844 + linuxkpi patch, drm-kmod c16de0f) and at HEAD,
then diffed `nm -m` undefined-external sets, segment/section layout and load
commands. Suspect commits c45dda4/de4b39c checked first by symbol provenance;
no rebuild-bisect past 02e386e needed — the diff isolated the change outright.

## Undefined externals diff (02e386e build vs HEAD, before fix)

02e386e binary: 1010 undefined externals. HEAD binary: 1040. New in HEAD:

| symbol (Mach-O name) | demangled | source | verdict |
|---|---|---|---|
| `__nmx_fw_<blob>_start` / `__nmx_fw_<blob>_end` × 28 | firmware blob markers (14 blobs × 2) | de4b39c fw-in-bundle | **unresolvable — firmware defect, not the complete OC failure explanation** |
| `__ZN11IOAccelTask8allocateEPK16IOAccelMemoryMap` | `IOAccelTask::allocate(IOAccelMemoryMap const*)` | 1089cc2 accel v2 | OK — IOAcceleratorFamily2 symbol, same kernel-stub path already proven at 02e386e |
| `__ZN11IOAccelTask10deallocateEPK16IOAccelMemoryMapy` | `IOAccelTask::deallocate(IOAccelMemoryMap const*, unsigned long long)` | 1089cc2 accel v2 | OK — same |
| `__ZN16IORangeAllocator9withRangeEyyjj` | `IORangeAllocator::withRange(unsigned long long, unsigned long long, unsigned int, unsigned int)` | 1089cc2 accel v2 | OK — IOGraphicsFamily symbol, same |

Removed: `___strncpy_chk` (harmless, fortify path change).

Segment/section layout: identical structure (no LC_LINKER_OPTION, same
segments); only `__TEXT,__const` grows 0x1297ac → 0x451488 (firmware bytes,
zero relocations — fine for kxld). kext 10.98 MB → 14.3 MB.

## Root cause: de4b39c (fw-in-bundle) — asm label underscore mismatch

`scripts/link.sh` generates the `.incbin` object with `.globl _nmx_fw_<s>_start`
and the firmware table (`nmx_firmware_table.cpp`) with
`extern "C" const unsigned char _nmx_fw_<s>_start[]`. On x86_64 Mach-O the C
driver prefixes one extra `_` to the extern "C" name, so the table references
`__nmx_fw_<s>_start` — but the assembler emits labels literally, defining only
`_nmx_fw_<s>_start`. Result: 28 dangling undefined externals whose GOT entries
sit in `nmx_firmware_table` (`__DATA,__got` 0x168 → 0x248, +54 external relocs).

kxld cannot resolve `__nmx_fw_*` against the Boot KC (not kernel symbols, not
declared in any OSBundleLibraries dependency), so OC prelinked injection dies:
`Invalid Parameter`, with `Vtable patching failed` as the downstream symptom —
exactly the failure signature. The dev host never saw it: FIRMWARE_ROOT is
staged at runtime so the table is never dereferenced, and `kmutil inspect -V tb`
does not link, so the dangling symbols passed every local check.

Why 02e386e worked: no embedded firmware, no such symbols. Everything between
(c45dda4 included) added no unresolvable externals.

## Fix

`scripts/link.sh`: emit `.globl __nmx_fw_<s>_start` / `__nmx_fw_<s>_end`
(double underscore) in the generated `.S`. The C++ table's `_nmx_fw_` spelling
is unchanged. One line of essence, plus a comment stating the constraint.

Regression guard: `scripts/fw-bundle.test.sh` now fails when `nm -m` shows any
UNDEFINED `_nmx_fw_*` symbol in the linked binary.

## Historical verification context

The commands below describe an older dev-host artifact and are not current
Tahoe build validation. Exact target ABI validation remains blocked on macOS
26.6.2 / build 25G83; the current source guard must continue rejecting Tahoe.
The old binary/prelink observations do not establish Tahoe support.

Hardware-gated: actual Tahoe RecoveryOS injection can only be confirmed on the
target machine. Keep Tahoe ABI status unvalidated.
