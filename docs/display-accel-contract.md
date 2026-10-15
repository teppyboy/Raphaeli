# Display + IOAccelerator split — lane contract (v0)

Single-writer rule. Each lane owns ONLY its files. Shared integration
(Info.plist personalities, link.sh object list, final link + kmutil) is
deferred to the integration lane — do NOT edit those.

## File ownership

| Lane | Owns (may create/edit) | Must NOT touch |
|------|------------------------|----------------|
| fb-display | xkpi/xnu/nmx_fb*.cpp, xkpi/xnu/nmx_fb*.h, xkpi/xnu/obj build of these | Info.plist, link.sh, bsdcompat/, override/ |
| accel      | xkpi/xnu/nmx_accel*.cpp, xkpi/xnu/nmx_accel*.h | Info.plist, link.sh, nmx_fb*, bsdcompat/ |
| scanout    | xkpi/bsdcompat/src/nmx_scanout.c, xkpi/override/display/**, xkpi/override/include/display/** | xnu/, Info.plist, link.sh |
| integration| Info.plist, link.sh, xnu build scripts, final validation | implementation files (bug reports only) |

## Kernel-internal interface (extern prototypes; scanout implements, fb calls)

```c
/* nmx_scanout.h — implemented in bsdcompat/src/nmx_scanout.c (scanout lane) */
kern_return_t nmx_scanout_alloc(size_t size, vm_offset_t *phys_addr,
                                vm_offset_t *kern_addr, vm_size_t *mapped);
kern_return_t nmx_scanout_free(vm_offset_t phys_addr, vm_size_t mapped);
/* WC mapping for userland exposure comes via existing GEM/dumb-buffer ioctls */
```

fb-display declares these prototypes itself (nmx_fb_internal.h); scanout
implements the exact signatures. Mismatches = integration failure.

## Accel submit hooks (accel lane defines thin extern wrappers; thin bodies
delegating to existing ring/fence paths live in nmx_accel*.cpp only):

```c
kern_return_t nmx_xnu_accel_ring_submit(uint32_t ring, uint64_t ib_addr,
                                        uint32_t ib_dw, uint64_t *fence_out);
kern_return_t nmx_xnu_accel_fence_wait(uint64_t fence, uint32_t timeout_ms);
```

## Modes/EDID policy (fb-display)

Milestone 1 = one fixed mode (panel-native if discoverable from VBIOS/EDID
via PCI ROM BAR or ACPI, else documented 1920x1080 placeholder). EDID
discovery is milestone 2. No I2C/HPD work in v0.

## Safety invariants (all lanes)

- IOAccelerator user clients must return kIOReturnUnsupported for unknown
  selectors — never panic on unknown input.
- RaphaeliFB must not attach unless BAR0 + scanout alloc succeed (mirror
  Raphaeli::start() BAR0 gate).
- Everything compiles with cc.sh/ccxx.sh flags (-mkernel -fapple-kext).
- No plist/link edits: each lane ends with an "integration needs" section
  in its report (exact personality dicts, exact link objects).
