# Display/accel review — disp-accel (out-disp lane)

Review of the display + accelerator lane (RaphaeliFB, RaphaeliAccel, nmx_scanout) as of 47e0aa9.
Findings and their applied fixes (kernel-side only; ocinject lane owns Info.plist/scripts/oc-install.py):

## P1-1 — RaphaeliFB::start binds any PCI-ID-matching device, even one Raphaeli never claimed
Raphaeli/Kernel/nmx_fb.cpp:72 (`bool start`) checked only BAR0 usability; the personality could start the
framebuffer on an unclaimed GPU. Fixed kernel-side by mirroring the accel gate (nmx_accel.cpp:81): start now
refuses unless the provider carries `nmxgpu-claimed`, which the main service sets after `nmx_port_attach()`
succeeds (Raphaeli/Kernel/nmx_kext.cpp:240) and re-offers via `pci_->registerService()` — exactly the accel
path (nmx_accel.cpp:78-85).

## P2 — nmx_scanout_alloc: WC mapping leaked on the pa==0 failure path
Raphaeli/Compat/src/nmx_scanout.c:67-71: when `pmap_mapdev_attr` succeeded but the `pa == 0` check failed,
`kmem_free` ran without `pmap_unmapdev`, leaking the WC mapping. Fixed: unmap before freeing when `wc != NULL`.

## P2 — RaphaeliAccel::stop leaked the fStamps IOBufferMemoryDescriptor
Raphaeli/Kernel/nmx_accel.cpp:170-181 (`getStampMemory`) prepares the descriptor and never releases it; stop()
(then a plain passthrough) dropped the only retain. Fixed: stop() now `complete()`s the prepared descriptor
(matching `prepare()`) and `release()`s it, matching the start-time retain, then nulls fStamps.

## P2 — RaphaeliFB::unregisterInterrupt was a no-op
Raphaeli/Kernel/nmx_fb.cpp:221-228: `unregisterInterrupt` returned success without dropping the VBL
registration, leaving the 60 Hz thread_call ticking after WindowServer unregistered. Fixed: unregister cancels
the timer and clears the callback (no-callback state); vblFire returns without re-arming when no callback is
registered, and registerForInterruptType re-arms the timer on re-registration (nmx_fb.cpp:213-230).

## Validation
- scripts/rt.sh: 78 runtime sources, 0 failed.
- scripts/link.sh out-disp: linked Raphaeli.kext (acfe142c, 10981984 B).
- kmutil inspect -V tb -p out-disp/Raphaeli.kext: exit 0 (root:wheel ownership warning pre-exists; ocinject lane owns install).
