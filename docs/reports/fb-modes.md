# fb-modes lane report: RaphaeliFB full mode list from the panel EDID

## What replaced the fixed 1920x1080 placeholder

`RaphaeliFB` now carries the whole mode list the VBIOS EDID supplies instead of one mode. The single-mode
`fbMode()` is `fbModes(provider, NMXFbMode *modes)` returning a count: it scans the PCI ROM BAR the same way
as before, takes the **first EDID 1.x block whose header + checksum validate and that yields at least one
sane mode**, and parses it with the new `nmx_fb_edid_modes()` (nmx_fb_internal.h). If nothing usable comes
out, the documented 1920x1080@60 placeholder stays as the only mode and the fallback is logged clearly
("no usable EDID in the VBIOS; keeping the documented 1920x1080@60 placeholder as the only mode").

## nmx_fb_edid_modes (host-testable, pure bytes → modes)

- All **four detailed timing descriptors** of the block (was: first only). Zero pixel-clock descriptors
  (monitor descriptors) are skipped; the existing sanity gate (20–400 MHz pclk, ≥640x400 active, non-zero
  blanking, ≤16k totals) is factored into `nmx_fb_mode_sane()` and shared.
- The **established-timing bitmap** (bytes 0x23..0x25): the 17 VESA slots (interlaced 1024x768@87 skipped)
  as a table of {w, h, refresh}, each turned into a timing by `nmx_fb_gtf_timing()`.
- The **8 standard-timing descriptors** (bytes 0x26..0x35): active area from width/8 + aspect code
  (16:10, 4:3, 5:4, 16:9), refresh 60–123; unused 0x0101 slots skipped; also GTF.
- `nmx_fb_gtf_timing()`: VESA GTF marginless/progressive — the established/standard blocks carry no
  blanking, so blanking/sync comes from the GTF formula and the pixel clock is set to hit the requested
  field rate **exactly** (`vfreq * vtotal * htotal`), so the listed refresh is honest. Same sanity gate as
  the EDID path.
- Modes are **deduplicated** by active area + refresh within 0.5 Hz (established/standard usually repeat
  the detailed timings) and **sorted preferred first**: byte 0x18 bit 1 moves the first detailed timing to
  slot 0 and marks it `preferred` (new NMXFbMode field). Cap: NMX_FB_MAX_MODES = 32.

## IOFramebuffer surface

- `getDisplayModeCount/getDisplayModes`: count, IDs = index+1 (mode 1 = preferred/startup).
- `getInformationForDisplayMode`: per-mode nominalWidth/Height, refreshRate 16.16 from
  `nmx_fb_refresh16()` (pclk/(htotal·vtotal)), Valid|Safe flags, Default only on mode 1 (also in
  `connectFlags`).
- `getTimingInfoForDisplayMode`: per-mode IODetailedTimingInformationV2 — pixel clock (= min = max),
  h/v active, blanking, sync offsets/widths — from the EDID/GTF numbers; kIODetailedTimingValid (without
  it WindowServer shows 0.00 Hz).
- `getCurrentDisplayMode`/`getStartupDisplayMode` return the current index (startup = preferred mode);
  `setDisplayMode`/`setStartupDisplayMode` accept any listed mode at depth 0 **if its pitch·height fits
  the scanout buffer** allocated for the startup mode — a larger mode is refused with a log line, because
  the display engine stays at the firmware timing and the buffer is fixed at startup size. Switching
  updates the aperture range, pixel info, and the VBL timer period (refresh/frame time of the new mode).
- Depth unchanged: XRGB8888 only, 32 bpp, 256-byte rows (`getPixelInformation` answers for any listed
  mode, depth 0; connection depth answers still advertise 32 bpp max).
- `initWith()` was never called (IOKit instantiates the default ctor); it is gone, replaced by
  `applyMode()` recomputing refresh/frame time for the current mode.

## Reference check

research/nvidia-macos-driver/gpu-port/xkpi/xnu/nmx_fb.cpp (NMXGPUFB) hardcodes one mode (getDisplayModeCount
1, modes[0]=1) — no multi-mode pattern to copy, so the mode-list plumbing follows the same override surface
it uses for the single mode; ID = index+1 is the natural extension.

## Validation

- `clang++ -std=c++17 -I Raphaeli/Kernel scripts/tests/nmx_fb_edid_test.cpp && ./a.out` → **all checks
  passed**. Extended fixtures: 3 detailed timings (1080p preferred + 720p + a 640x480 that dedups against
  the established bitmap), established bits 640x480@60 + 800x600@60, one standard 1280x720@60 → exactly 4
  modes in the right order with exact DTD fields; refresh-within-1 Hz + sanity ranges for every GTF mode;
  no-preferred-bit EDID order preserved; truncation at max=3 with preferred still first; bad-checksum and
  null-argument rejection; standalone GTF checks (1024x768@70 → 70 Hz exact, hblank cell-aligned).
- `./scripts/ccxx.sh Raphaeli/Kernel/nmx_fb.cpp` → clean, no warnings; `nm -u xnuobj/nmx_fb.o` externs
  unchanged (scanout + pci + IOKit libs).
- `./scripts/build.sh` → 900/900 sources, 0 failed; `./scripts/rt.sh` 0 failed; `./scripts/link.sh
  out-disp` → Raphaeli fe622e1b, links clean.
- `kmutil inspect -V tb -p $PWD/out-disp/Raphaeli.kext` → exit 0 (INSPECT_OK), as in prior lanes.

## Risks

- setDisplayMode is nominal: nothing reprograms the display engine (same as before); a switched "mode"
  only changes what WindowServer renders into the scanout buffer, and the panel keeps its firmware timing.
  Only the startup (preferred) mode is guaranteed to look right on real hardware.
- GTF timings are formula-derived, not panel-verified; they are only offered as secondary modes and pass
  the same sanity gate as the EDID ones.
- The scan takes the first EDID block that yields modes; extension blocks (128-byte continuation) and
  their detailed timings are still ignored (unchanged scope from milestone 1).
- VBIOS ROM bigger than 128 KiB or EDID beyond it is not scanned (unchanged).

## Self-check artifacts

- pi-lens flagged `sum` out-of-scope issues in the test loop rewrite mid-session; fixed by a `checksum()`
  helper and verified by a clean compile+run. One edit-tool splice mangled nmx_fb_internal.h mid-edit;
  repaired and both the header (ccxx.sh) and the test re-verified clean afterwards.
