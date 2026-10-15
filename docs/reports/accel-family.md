# IOAccelerator family lane — Raphaeli accel skeleton (v0)

Files: `xkpi/xnu/nmx_accel.h`, `xkpi/xnu/nmx_accel.cpp` (nub + contract submit hooks),
`xkpi/xnu/nmx_accel_uc.cpp` (vendor objects). Built with `./ccxx.sh` →
`xnuobj/nmx_accel.o`, `xnuobj/nmx_accel_uc.o`. Nothing else touched (no Info.plist,
no link.sh, no bsdcompat, no nmx_fb*).

## 1. Surface map (what macOS 15 actually needs)

**Class hierarchy (authority: the reference driver's reconstructed headers,
`research/nvidia-macos-driver/kexts/NVRM/accel/re/` + `iofam/`, read out of the shipped
IOAcceleratorFamily2 binary; Apple publishes no IOAccel headers — nothing named
`IOAccel*` exists in the KDK IOKit framework or Kernel.framework).**

```
IOService → IOAccelerator (136 B, IOGraphicsFamily, no new virtuals)
          → IOGraphicsAccelerator2 (3544 B, IOAcceleratorFamily2, 84 new virtuals, 17 pure)
              ← RaphaeliAccel                    (the nub; family user clients attach to it)
IOUserClient family classes (implemented IN the family, vendor never subclasses them):
  IOAccelerationUserClient / IOAccelDevice2 (10 selectors, sDeviceMethods legacy
  IOExternalMethod[10]) / IOAccelSharedUserClient2 / IOAccelDisplayPipeUserClient2 /
  IOAccelMemoryInfoUserClient / IOAccelCommandQueue2
Vendor objects the family's factories ask for (all implemented in nmx_accel_uc.cpp):
  IOAccelEventMachineFast2 (pure: writeStamp, prepareBarrier, completeBarrier,
                            writeBarrierElement) ← RaphaeliEventMachine
  IOAccelLegacyDisplayMachine (displayModeWillChange/DidChange) ← RaphaeliDisplayMachine
  IOAccelTask (allocate/deallocate)                        ← RaphaeliTask
  IOAccelMemoryMap (commit/release/updateGPUPageTable)     ← RaphaeliMemoryMap
  IOAccelResource2 (paging-buffer/aperture hooks)          ← RaphaeliResource
  IOAccelSysMemory / IOAccelVidMemory (alloc/deallocPhysical) ← Raphaeli(Sys|Vid)Memory
  IOAccelLegacySurface (pure: setSyncCommand, _pure335)    ← RaphaeliSurface
  IOAccelGLContext2 (pure: _pure362/363/364/367)           ← RaphaeliGLContext
  IOAccel2DContext2 (pure: _pure362/363)                   ← Raphaeli2DContext
  IOAccelCLContext2 / IOAccelVideoContext2 (no pure)       ← RaphaeliCL/VideoContext
```

**Command-buffer submit, kernel-side (family model):** WindowServer opens
`IOAccelerationUserClient` on the accelerator nub → device config via
`populateAccelConfig` → client contexts created via `newGLContext`/`new2DContext`/
`newCLContext`/`newVideoContext` → per-submit the family's `IOAccelContext2` walks the
command descriptors (sideband tokens, data buffers), maps resources through
`IOAccelMemoryMap::commitIntoGPUPageTable` (the vendor GART hook), stamps events
through `IOAccelEventMachineFast2::writeStamp`, and gates every allocation on
`IOGraphicsAccelerator2::enableAccelerator()` (flag 0x2 at ivar 0xc78 — the family
sleeps in `acceleratorWaitEnabled()` until it is set; we call `enableAccelerator()`
in `start()`). The engine submit itself is vendor-side — in the reference the family
model never drives the engine: rendering goes through the vendor's own client path.

**Discovery surface for the nub (from the reference Info.plist):**

| field | value |
|---|---|
| IOProviderClass | `IOPCIDevice` |
| IOClass | `RaphaeliAccel` |
| IOPCIPrimaryMatch | `0x00001002&0x0000ffff` (+ a second personality for `0x00008086&0x0000ffff`, or one with both) |
| IOPCIClassMatch | `0x03000000&0xff000000` |
| IOMatchCategory | `IOAccelerator` (distinct category is what allows both `Raphaeli` and `RaphaeliAccel` on the same PCI function) |
| IOProbeScore | 100 |
| (withheld, v1) | `MetalPluginName`/`MetalPluginClassName` — do NOT set until a Metal plugin exists; an armed name with no plugin stalls Metal |

`IOServiceOpen` succeeds once `RaphaeliAccel::start()` ran
`IOGraphicsAccelerator2::start()` + `registerService()` + `enableAccelerator()`:
`newUserClient` is then the family's own implementation (it creates every standard
client type and returns `kIOReturnUnsupported` for unknown types itself).

**Start gate:** `probe()` requires PCI class 03 and vendor 0x1002/0x8086;
`start()` additionally requires the provider property `nmxgpu-claimed` (set by the
main `Raphaeli` service in `nmx_kext.cpp` after its attach thread finishes, which
re-runs matching on the device) — same gate the reference's NMX build uses. A GPU the
Raphaeli driver does not run amdgpu on never gets an accelerator.

## 2. Per-selector / per-hook status

| family hook | status |
|---|---|
| `newUserClient` (all types) | **ported-by-family**: delegated to `IOGraphicsAccelerator2::newUserClient`; unknown types → family returns kIOReturnUnsupported. Logged (capped). |
| `IOAccelDevice2` selectors 0–9 (get_config, get_name, get_event_machine, get_surface_info, set_stereo, get_next_global_object_id, get_current_trace_filter, get_device_info, get_next_gid_group, set_api_property) | **ported-by-family**: implemented inside IOAcceleratorFamily2 (`sDeviceMethods`); vendor-independent; config comes from our `populateAccelConfig`. Out-of-range selectors → family's `getTargetAndMethodForIndex` returns NULL → kIOReturnUnsupported. Never panics. |
| `populateAccelConfig` | **ported** (offsets = family Sequoia layout, modest caps; page-crossing guard kept from the reference) |
| `getStampMemory`, event machine stamps | **ported** (one contiguous 16 KB stamp page; `writeStamp` writes it) |
| barriers, `checkGPUProgress`/`checkChannelProgress` | **stubbed** (return true / ignored — no family channels in use) |
| `IOAccelTask::allocate` | **stubbed** — returns 0 (no GPU page tables; refusing beats handing out colliding fake VAs) |
| `IOAccelMemoryMap::commitIntoGPUPageTable` | **stubbed** — false (the vendor GART hook; no page tables exist) |
| `IOAccelResource2::addToAperture` / aperture descriptor | **stubbed** — false/NULL |
| `IOAccelVidMemory::allocPhysical` | **stubbed** — false (VRAM allocation belongs to amdgpu; no bridge yet) |
| surface copy/swap/shape | **stubbed** — logged, no flip engine (the panel is RaphaeliFB's) |
| contexts (GL/2D/CL/video) | **stubbed** — pure hooks quiet; the family runs their command stream until it needs a real mapping, then fails honestly |
| `nmx_xnu_accel_ring_submit` | **stubbed** — logs (first 8, then every 1024th), returns `KERN_NOT_SUPPORTED`, never executes |
| `nmx_xnu_accel_fence_wait` | **stubbed** — same |

Unknown-selector safety: no `switch` dispatch of our own exists anywhere in the lane;
every unknown input either stays inside the family's dispatch (unsupported return) or
lands in one of the above no-op virtuals. Nothing can panic on unknown input.

## 3. Submit mapping (design + why v0 refuses)

Contract hooks `nmx_xnu_accel_ring_submit` / `nmx_xnu_accel_fence_wait` are defined in
`nmx_accel.cpp` (extern "C", one spelling, kernel-internal interface per the lane
contract). The intended target is the existing amdgpu submit path RADV drives:
`/dev/dri/renderD*` ioctl → `drm_ioctl` → `amdgpu_cs_ioctl` (cs parser: BO list,
syncobj deps, `amdgpu_ib_schedule` per ring, `dma_fence` out). That path is
parser-shaped: it needs a `drm_file`, a `struct amdgpu_cs_parser` and the LinuxKPI
headers — none of which can be included from this IOKit-side TU (`ccxx.sh` is
`-nostdinc` + Apple headers only; the bridge pattern used by the fb lane
`override/src/nmx_fb_bridge.c` + `nmx_port.h` lives in files this lane does not own).
So v0 does what the contract allows: log + `KERN_NOT_SUPPORTED`, no execution, no
pretended success. Wiring it for real = one C-side bridge function in a
`nmx_accel_bridge.c`-style file (integration lane / new lane decision) + a 3-line body
here.

## 4. Integration needs (exact, for the integration lane)

**Info.plist — add one personality per vendor (or merge into one):**

```xml
<key>RaphaeliAccel</key>
<dict>
  <key>CFBundleIdentifier</key><string>me.tretrauit.raphaeli</string>
  <key>IOClass</key><string>RaphaeliAccel</string>
  <key>IOProviderClass</key><string>IOPCIDevice</string>
  <key>IOPCIPrimaryMatch</key><string>0x00001002&amp;0x0000ffff</string>
  <key>IOPCIClassMatch</key><string>0x03000000&amp;0xff000000</string>
  <key>IOMatchCategory</key><string>IOAccelerator</string>
  <key>IOProbeScore</key><integer>100</integer>
</dict>
<!-- plus an identical RaphaeliAccelIntel personality with IOPCIPrimaryMatch 0x00008086&0x0000ffff -->
```

No `IOUserClientClass` keys are needed: the family's `IOGraphicsAccelerator2::newUserClient`
creates all client classes itself (that is the reference's shape too).

**OSBundleLibraries — add:**

```xml
<key>com.apple.iokit.IOAcceleratorFamily2</key><string>2.0.0</string>
```

(IOSurface is pulled in transitively by the family on the reference's plist; add
`com.apple.iokit.IOSurface` too if kmutil complains.)

**link.sh — add to the object list:**

```
xnuobj/nmx_accel.o xnuobj/nmx_accel_uc.o
```

**Header location:** the lane includes the reference's reconstructed family headers
from `research/nvidia-macos-driver/kexts/NVRM/accel/{re,iofam}/` by relative path.
If the integration lane wants the kext tree self-contained, copy those two directories
into e.g. `xkpi/include/ioaccel/` and fix the two include blocks in `nmx_accel.h`
(one-line change). Those headers are PolyForm-Noncommercial-licensed (NullMoth) —
check the license before shipping.

**Validation used:** KDK_15.7.8 family binary exports 1081 of the 1083 family symbols
our objects reference (the 2 extras are our own statics; dry-linked our two objects
into a Mach-O kext bundle cleanly). The 2 non-exported-in-the-standalone-binary
inherited slots (`tmpTotalVRAM`, `totalTextureMemory` are `t` local there) are the same
references the field-proven reference driver carries; kxld binds them from the
SystemKernelExtensions.kc at load.

## 5. Risks — what will still fail and why

1. **No VRAM/GART bridge** → every resource allocation (`allocPhysical`,
   `addToAperture`, map commit) refuses. Clients can OPEN and query, but cannot create
   usable buffers. This is the deliberate v0 line until the C-side bridge exists.
2. **No Metal plugin** (`MetalPluginName` not set) → no app-facing Metal device yet;
   the accelerator nub is only discoverable via IOKit. Setting the key before a plugin
   exists would be worse (Metal stalls).
3. **vtable-order / class-size risk** is inherited from the reconstructed headers —
   they are machine-generated and size-asserted for macOS 15 x86_64; a macOS update
   that changes family internals breaks this lane loudly at kmutil/link time.
4. **`tmpTotalVRAM`/`totalTextureMemory` bind**: local symbols in the standalone
   family binary; expected to bind from the kernel collection like the reference's
   do, but only the real kmutil run proves it.
5. **WindowServer will still not composite on this GPU**: display is RaphaeliFB's;
   the accel lane v0 has no display pipe (family default) — same headless shape the
   reference NMX build ships with.
6. `IOAccelDevice2` selector payloads (IOAccelDeviceConfigData etc.) are opaque in the
   reconstructed header; `get_config` is family-side so this is invisible to us unless
   the family's expectations of `populateAccelConfig` offsets drift (see risk 3).
