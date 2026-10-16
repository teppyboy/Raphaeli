# Tahoe 26.6 IOAccel binary audit

Compared actual x86_64 KDK binaries, not macOS marketing versions:

- Sequoia 15.7.8 24G824, IOAcceleratorFamily2 v485.
- Tahoe 26.6 25G72, IOAcceleratorFamily2 v487.4.3 (download/checksum provenance in
  [OC vtable reproduction](oc-vtable-reproduction.md)).

Host-only read-only analysis. No runtime driver load, no Apple kext deployment.

## Referenced exports

Intersected current `nm -u out-disp/Raphaeli.kext/Contents/MacOS/Raphaeli`
with `nm -arch x86_64 -gU` Sequoia IOAcceleratorFamily2 exports, then subtracted
Tahoe IOAcceleratorFamily2 exports: **zero missing symbols**.

This is bounded to imports provided by that family. It does not check all
Raphaeli imports against the target Recovery KC, prove class storage sizes,
or verify method semantics.

## Vtable slot comparison

Used the existing research `tools/vtdump.py` (classic Mach-O symbol/relocation
parser, read-only) on both standalone x86_64 IOAcceleratorFamily2 binaries.
Every symbol-name entry compared equal, including inherited entries. Counts
exclude the two ABI header words:

| Base class used by Raphaeli | Sequoia slots | Tahoe slots | Different entries |
| --- | ---: | ---: | ---: |
| IOGraphicsAccelerator2 | 350 | 350 | 0 |
| IOAccelTask | 51 | 51 | 0 |
| IOAccelMemoryMap | 57 | 57 | 0 |
| IOAccelResource2 | 79 | 79 | 0 |
| IOAccelSysMemory | 66 | 66 | 0 |
| IOAccelVidMemory | 69 | 69 | 0 |
| IOAccelLegacySurface | 334 | 334 | 0 |
| IOAccelGLContext2 | 373 | 373 | 0 |
| IOAccel2DContext2 | 368 | 368 | 0 |
| IOAccelCLContext2 | 366 | 366 | 0 |
| IOAccelVideoContext2 | 366 | 366 | 0 |
| IOAccelEventMachineFast2 | 95 | 95 | 0 |
| IOAccelLegacyDisplayMachine | 298 | 298 | 0 |

Scratch evidence: `/tmp/raphaeli-tahoe-audit/missing-imports.txt` and
`/tmp/raphaeli-tahoe-audit/vtable-comparison.txt`.

## Conclusion and limits

For **these two binaries**, no IOAccel import-name or base-vtable slot-order
change justifies speculative Tahoe forwarding overrides or declaration edits.
The existing observed prelink failure is explained locally by unavailable
superclass vtables, not a demonstrated mismatch in these slot lists.

Still unverified: exact target build (25G72 is not yet confirmed as target),
class sizes/private ivar offsets, WindowServer handshake, GPU VM, submission,
and actual acceleration. Later Tahoe revisions may differ; no claim of universal
Tahoe ABI compatibility. The research tree's forwarding code targets a different
26.7.1 binary and must not be applied blindly to 26.6.
