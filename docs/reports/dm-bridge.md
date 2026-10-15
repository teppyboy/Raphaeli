# Display-engine bridge lane report: RaphaeliFB mode changes run on the real DC core

Closes review P1-2 (disp-accel-review.md): `RaphaeliFB::setDisplayMode` was nominal — it updated the
mode index and derived the VBL period but never programmed a scanout. The mode change now runs on the
amdgpu port's real DCN display core (already compiled in from kpi/drm-kmod by scripts/build.sh:
amdgpu_dm + dc/dcn31 + dmub), without going through DRM.

## What was added

- `Raphaeli/Kernel/nmx_dm_bridge.h` — the boundary header (Kernel-side consumer, Override-side
  implementation, the same shape as the accel bridge's boundary in nmx_port.h). Plain types only;
  results are 0 or a negative errno. The C++ consumer includes it inside `extern "C"` (no C++
  linkage guard in Kernel-dir headers).
- `Raphaeli/Override/src/nmx_dm_bridge.c` — the amdgpu-side implementation.
- `Raphaeli/Kernel/nmx_fb.cpp` — RaphaeliFB wiring (below).
- `Raphaeli/Kernel/nmx_fb_internal.h` — `NMXFbMode` now carries the sync shape the engine must drive:
  `interlace`, `positive_vsync`, `positive_hsync` (EDID detailed-timing byte 0x11: bit 7 interlace,
  bits 2/1 positive V/H sync, the same bits drm's `DRM_EDID_PT_INTERLACED`/`_HSYNC_POSITIVE`/`_VSYNC_
  POSITIVE` read; GTF timings get -H +V per drm_gtf_mode's polarity). The struct gained a typedef so
  the C side can use the bare name; the GTF path now assigns fields (no compound literal — the header
  compiles as C too). Host test scripts/tests/nmx_fb_edid_test.cpp still passes.

## The DC calls used (the kernel-internal shape of amdgpu_dm's own modeset, no DRM)

- Device resolution: `nmx_device_for_pci` -> `device_get_children` -> `pci_get_drvdata` ->
  `drm_to_adev`, exactly the walk nmx_accel_bridge.c uses. Gates: `adev->accel_working`,
  `!in_suspend`, `!shutdown`, `adev->dm.dc->current_state` live.
- Connector enumeration (`nmx_dm_bridge_init`): `dc->links[i]` / `dc->link_count`, connected means
  `link->local_sink != NULL`; eDP (`SIGNAL_TYPE_EDP`) sorts first. Returns the count; RaphaeliFB
  logs it and uses connector 0 (one head per framebuffer in v1).
- Stream build (`nmx_dm_bridge_set_mode`): `dc_create_stream_for_sink(link->local_sink)`, then the
  NMXFbMode-shaped part of dm's `fill_stream_properties_from_drm_display_mode`: `dc_crtc_timing`
  from width/blanking/sync offsets (pix_clk_100hz = pclk/100), `PIXEL_ENCODING_RGB`,
  `COLOR_DEPTH_888`, `TIMING_3D_FORMAT_NONE`, sync polarities/interlace from NMXFbMode; stream
  `src`/`dst` = the full active area, SRGB out transfer, SRGB output color space.
- Pre-check: `dc_validate_stream` (DC_OK or refuse before touching hardware).
- Commit: `dc_commit_streams` with one stream and `DC_POWER_SOURCE_AC` — this is the call
  `amdgpu_dm_commit_streams` ends in; it validates, assigns link encoders and enables the stream
  (link training for eDP included) inside the commit.
- Plane: `dc_create_plane_state` + `dc_update_planes_and_stream` with one
  `dc_surface_update` (flip_addr = the scanout physical run as `PLN_ADDR_TYPE_GRAPHICS`
  `grph.addr`, plane_info = linear XRGB8888 `SURFACE_PIXEL_FORMAT_GRPH_ARGB8888`, gfx9 device
  tiling constants + `DC_SW_LINEAR`, scaling = 1:1 full rect) — where `amdgpu_dm_commit_planes`
  ends. The previously committed stream is detached first (planes + stream removed in a
  `dc_state_create_current_copy`, then a 0-stream `dc_commit_streams`, the shape of
  `amdgpu_dm_commit_zero_streams`) so one pipe is never over-committed. Everything under
  `adev->dm.dc_lock`, like every dm commit. The committed plane's address is read back from
  `dc_stream_get_status(stream)->plane_states[0]->address` and reported to the caller.

## RaphaeliFB wiring (Kernel/nmx_fb.cpp)

- `start()` (after the claim/BAR0/scanout gates): `nmx_dm_bridge_init`; on success one best-effort
  `nmx_dm_bridge_set_mode` with the startup (preferred) mode and the scanout physical run — the
  panel lights with panel-native timing at boot, before WindowServer. Engine unavailable or commit
  refused: logged, framebuffer still starts (firmware timing stays on the panel).
- `setDisplayMode`/`setStartupDisplayMode`: bridge set-mode; failure logs and returns
  `kIOReturnUnsupported` — the display keeps the previous real timing instead of lying about
  success (review P1-2 'decline or program'). The mode index/refresh bookkeeping updates only on
  success. VBL stays the 60-ish Hz thread_call timer; a real vblank interrupt hookup
  (IRQ_TYPE_VBLANK via dc_interrupt_set) is a follow-up.

## Expected behavior on hardware (raphaeli-amd=1)

1. Raphaeli claims the GPU, the amdgpu port runs full device init (`amdgpu_dm_init` inside it brings
   up dc/dmub and detects the eDP panel).
2. RaphaeliFB starts on the claimed device, allocates the scanout buffer, and the bridge commits the
   EDID-preferred timing: DC trains the eDP link, enables the OTG and scans out the black scanout
   buffer from its physical address (below 4 GB contiguous wired RAM). The panel lights with
   panel-native mode; the console/WindowServer then draw into the same buffer with no copy.
3. Mode switches re-run the bridge (detach old stream -> commit new -> attach plane); unsupported
   timings are declined with the old timing intact.

## Risks

- The scanout buffer is wired system RAM, not VRAM. On APUs (unified memory) DC scans out of system
  RAM fine, but `nmx_fb_before_attach` sets `amdgpu_sg_display=0` (the fb bridge's old policy); DC
  validation of a system-memory plane does not consult that knob, but if a dGPU is ever targeted the
  scanout allocation must move to VRAM (nmx_scanout.c v1 TODO).
- Backlight: dm sets panel backlight in its own commit path; this bridge does not, so the panel
  comes up at the firmware's backlight level. A `dc_link_...`/backlight hookup is a follow-up.
- Polarities/interlace now come from the EDID DTD byte 0x11 bits; the established/standard-timing
  GTF paths assume -H +V (drm's GTF polarity). Panels whose GTF-listed timings deviate would be a
  validation refusal (declined, not misprogrammed).
- v1 assumptions: one head, one GPU, connector 0 = eDP; hotplug after init is not re-enumerated (the
  sink was detected at driver init; link->local_sink is re-read per set-mode, so a re-detected sink
  on the same link is picked up, a physically different panel is not).
- The stream detach uses a 0-stream commit; on multi-head systems that would blank other heads —
  safe only under the one-head v1 contract.

## Validation

- scripts/build.sh: 900/900 sources, 0 failed.
- scripts/rt.sh: 79 runtime sources, 0 failed (includes Override/src/nmx_dm_bridge.c and
  Kernel/nmx_fb.cpp).
- scripts/link.sh out-disp: linked Raphaeli.kext (5f3af476, 10990624 B).
- kmutil inspect -V tb -p out-disp/Raphaeli.kext: exit 0.
- scripts/tests/nmx_fb_edid_test.cpp: all checks passed.
