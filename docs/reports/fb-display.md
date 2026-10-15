# fb-display lane report: RaphaeliFB as a real IOFramebuffer

## Reference survey (research/nvidia-macos-driver/gpu-port)

The reference driver's IOFramebuffer is `gpu-port/xkpi/xnu/nmx_fb.cpp` (`NMXGPUFB : IOFramebuffer`) —
byte-for-byte the same design as our old scaffolding (our file was a renamed copy), which the README says
"met the same WindowServer". Its minimal complete override surface on macOS 15 (Kernel.framework
IOFramebuffer, no IOFramebufferSwift):

- `start/stop` — start registers power (registerPowerDriver), arms a thread_call 60 Hz timer as the VBL
  (no display interrupt wired); stop cancels + frees the timer (`thread_call_cancel_wait` is not kext-exported).
- `enableController`, `isConsoleDevice` (true — console text lights through the framebuffer).
- `getApertureRange(kIOFBSystemAperture)` / `getVRAMRange` — IODeviceMemory::withRange over the scanout
  physical range; this is what WindowServer maps for scanout. No IOMemoryDescriptor dance needed.
- Pixel answers: `getPixelFormats` (IO32BitDirectPixels), `getPixelInformation` (XRGB8888 masks,
  bytesPerRow, activeWidth/Height), `getPixelFormatsForDisplayMode`.
- Mode list: `getDisplayModeCount` (1), `getDisplayModes`, `getInformationForDisplayMode`
  (nominalWidth/Height, refreshRate in 16.16, Valid|Safe|Default flags), `getTimingInfoForDisplayMode`
  (IODetailedTimingInformationV2 + kIODetailedTimingValid — without it WindowServer shows 0.00 Hz),
  `getCurrentDisplayMode`, `getStartupDisplayMode`, `setDisplayMode`, `setStartupDisplayMode`.
- Connection: `getConnectionCount` (1), `connectFlags`, `getAttributeForConnection`
  (kConnectionEnable/CheckEnable=1, color modes/depths supported), `setAttributeForConnection`
  (kConnectionPower & friends = success), `getAttribute`/`setAttribute` (kIOWindowServerActiveAttribute,
  kIOPowerAttribute with did-power-on/will-power-off handleEvent; unknown falls through to IOFramebuffer).
- Interrupts: `registerForInterruptType` (kIOFBVBLInterruptType, kIOFBConnectInterruptType stored;
  others kIOReturnUnsupported), `unregisterInterrupt`, `setInterruptState`.
- Color/power no-ops: `setGammaTable` (both overloads), `setCLUTWithEntries`, `setApertureEnable`,
  `setPowerState` (acknowledged immediately with kIOPMAckImplied — deferring waits on a shared thread).

What it does NOT implement (and we don't either): cursor overrides, DDC/I2C, `getAttribute` beyond the
defaults, and any IOMemoryDescriptor construction — IODeviceMemory::withRange suffices for scanout.

## Design of the new nmx_fb.cpp (+ nmx_fb_internal.h)

- `RaphaeliFB : IOFramebuffer` now matches the GPU's **IOPCIDevice directly** (personality added by the
  integration lane, below) instead of being hand-published from `Raphaeli::attachNow()` through the port
  bridge. Same proven override surface as the reference.
- `start()` gates, mirroring `Raphaeli::start()`'s BAR0 audit:
  1. provider must be an IOPCIDevice with a usable MMIO BAR0 (`nmx_xnu_pci_bar_info`, non-zero, non-I/O) —
     else log + return false (firmware framebuffer keeps the screen);
  2. `nmx_scanout_alloc(pitch*height, ...)` (contract extern, declared in `nmx_fb_internal.h`, implemented
     by the scanout lane) must succeed with `mapped >= want` — else same.
  Only then `IOFramebuffer::start`, PMinit/joinPMtree/registerPowerDriver, VBL timer.
- `stop()`: VBL timer torn down, `nmx_scanout_free`, then `IOFramebuffer::stop`.
- Mode: **panel-native from the VBIOS**. `nmx_xnu_pci_rom()` (existing, nmx_pci.cpp) reads the ROM via the
  PCI ROM BAR (or vbios/rom DeviceProperties); we scan for an 8-byte EDID header with valid checksum and
  parse the detailed-timing block into `NMXFbMode` (`nmx_fb_edid_timing`, in `nmx_fb_internal.h`, pure
  bytes→struct). If no sane EDID block is found: documented 1920x1080@60 placeholder (148.5 MHz, standard
  1080p blanking/sync) — the contract's milestone-1 fallback; VBT/EDID discovery beyond this is milestone 2.
- Pixel geometry fixed: XRGB8888, 32 bpp, rows aligned to 256 bytes; refresh/frame time derived from
  pclk/(htotal·vtotal); everything unknown → kIOReturnUnsupported / sane defaults, never panic.
- The parse logic is host-testable: `nmx_fb_edid_test.cpp` (assert-based, real EDID byte layouts incl.
  2-bit-high sync fields, checksum/pclk/active-area rejection, pitch alignment). Not part of the kext link.

## Integration lane needs (exact, do not improvise)

1. **Info.plist** (`kext/Info.plist`), inside `IOKitPersonalities`, alongside the existing Raphaeli dict:

```xml
<key>RaphaeliFB</key>
<dict>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>   <!-- same value the Raphaeli personality uses -->
    <key>IOClass</key>
    <string>RaphaeliFB</string>
    <key>IOProviderClass</key>
    <string>IOPCIDevice</string>
    <key>IOProbeScore</key>
    <integer>1000</integer>
</dict>
```

   Notes: match the same display-class devices the Raphaeli personality matches (add the same
   `IOPCIClassMatch`/`IOPCIPrimaryMatch` keys the Raphaeli dict has, if any — RaphaeliFB deliberately has no
   opt-in check of its own; it refuses to attach only via the BAR0 + scanout gates in code). IOProbeScore
   1000 keeps RaphaeliFB competitive; if integration wants RaphaeliFB to yield to Raphaeli ordering, lower
   it — matching order between two services on one provider does not gate either.

2. **link.sh**: no change needed — `xnuobj/nmx_fb.o` is already in the object list and the object name
   is unchanged.

3. **nmx_kext.cpp** (integration may edit; fb lane may not): drop `nmx_fb_publish`/`nmx_fb_unpublish`
   (declarations at nmx_kext.cpp:31-32, calls at :244 and :259) once the personality lands. Until then the
   stubs in nmx_fb.cpp keep the link green: `nmx_fb_publish` returns nullptr (attachNow proceeds without a
   bridge fb), `nmx_fb_unpublish(nullptr,…)` no-ops.

4. **kext/Info.plist** must gain nothing else; IOKit personality matching + `isConsoleDevice()` is what
   binds the console. pmset/sleep path handled via kIOPowerAttribute + setPowerState as in the reference.

5. Scanout lane's `bsdcompat/src/nmx_scanout.c` must be on the link (srcobj/ or obj/ per their build) or
   the final link fails on `nmx_scanout_alloc`/`nmx_scanout_free` — expected until their lane lands.

## What happens on attach (expected behavior)

- BAR0 valid + scanout alloc OK → RaphaeliFB publishes, WindowServer binds it, console text lights through
  the scanout buffer; WindowServer itself stays software (accel lane separate).
- Gate failure → "Raphaeli display: no usable MMIO BAR0 …" / "scanout allocation failed …" in the log and
  the firmware framebuffer keeps the screen. RaphaeliFB does not check the raphaeli-amd/intel opt-in; on a
  machine where the user did NOT opt in, it still allocates one scanout buffer and publishes — harmless for
  the GPU (nothing resets the display engine from this lane) but integration may want the personality
  keyed off the same opt-in if that is deemed unacceptable.

## Validation

- `./ccxx.sh xnu/nmx_fb.cpp` → clean, no warnings; `xnuobj/nmx_fb.o` rebuilt.
- `nmx_fb_edid_test.cpp` host run → all checks passed.
- `nm -u xnuobj/nmx_fb.o` → only expected externs: nmx_scanout_alloc/free (scanout lane),
  nmx_xnu_pci_bar_info/nmx_xnu_pci_rom (nmx_pci.o), plus IOKit/kmod libs.
- nmx_fb_publish/unpublish still defined → nmx_kext.o link stays green.

## Risks

- Without the scanout lane's nmx_scanout.c the kext does not link (undefined nmx_scanout_alloc/free).
- RaphaeliFB matches every display-class IOPCIDevice (no vendor/device filter of its own); on unclaimed
  GPUs it allocates a scanout buffer it cannot scan out from. If undesirable, gate via personality keys.
- EDID-in-VBIOS heuristic: first valid-checksum block wins; a VBIOS with a stale/odd embedded EDID gives a
  wrong native mode (sane-range checks applied). Placeholder mode covers the failure case.
- getVRAMRange/getApertureRange hand out the scanout physical range; if the scanout lane's buffer is not
  actually scan-out-capable at that physical address, WindowServer binds but the display stays dark.

## Self-check artifacts

- pi-lens initial-check noise: first-write checks of new files ran a header-less fallback parse (no
  compile_commands entry for xnu/*.cpp). Fixed by extending `gen_ccdb.sh` with ccxx.sh-flag entries for
  `xnu/*.cpp` (additive; regenerated compile_commands.json now has 31 entries). All files recheck clean.
