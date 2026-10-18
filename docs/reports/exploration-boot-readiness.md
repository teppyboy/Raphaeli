# Boot-readiness exploration

Date: 2026-03-10

## Scope

Read the boot-critical entry points, attach path, PCI validation, firmware lookup, bus attach/detach, display claim, build/link scripts, and host tests. No production code changed.

## Boot path

1. `Raphaeli/Info.plist` matches AMD display-class PCI functions vendor-wide; `Raphaeli::probe()` declines unless `raphaeli-amd=1`, `raphaeli-intel=1`, or `raphaeli-gpu` is set. `-amdgpuoff` parks the driver before opt-in.
2. `Raphaeli::start()` requires a non-I/O BAR0 with nonzero size and at least one MSI vector before starting the port.
3. `nmx_port_start()` initializes kernel, allocators, sleep/callout/taskqueue, devfs, then SYSINIT; failure unwinds through `nmx_port_stop()`.
4. Attach is moved to a kernel thread. It waits up to 300 seconds for firmware root only when no embedded blobs exist, checks the NVRAM marker, sets the marker, calls `nmx_port_attach()`, then clears the marker only after PM/service/claim publication and accelerator self-test.
5. `nmx_port_attach()` creates the PCI record, offers the device to `vgapci`, counts attached children, and removes the record if no driver attaches.
6. `RaphaeliFB` starts only after `nmxgpu-claimed`, validates BAR0 again, allocates scanout, starts IOFramebuffer, initializes DCN, and programs the startup mode when possible.

## Evidence

- Working: `./scripts/oc-install.test.sh` — all tests passed.
- Working: `clang++ -std=c++17 -I Raphaeli/Kernel scripts/tests/nmx_fb_edid_test.cpp -o /tmp/nmx_fb_edid_test && /tmp/nmx_fb_edid_test` — all checks passed.
- Working: `python3 scripts/tests/boot_arg_gate_test.py` — renamed `-amdgpuoff` gate verified.
- Working: `bash -n scripts/*.sh; python3 -m py_compile scripts/*.py; plutil -lint Raphaeli/Info.plist`.
- Not runnable as-is: `./scripts/install.test.sh` expects a built `out/Raphaeli.kext` and hard-codes `/Users/yuuki/.../firmware`; this checkout has no `out/` or `firmware/` build trees. The failure is test-fixture/environment drift, not a confirmed boot failure.

## High-risk areas for the next bug

- Hardware attach remains unverified: this host has no Phoenix 780M.
- The attach thread has a 10-minute bounded wait in `stop()`; if the firmware wait or driver attach hangs, stopping can continue after timeout while the worker still owns the object. This requires targeted lifecycle review before hardware loading.
- The boot marker is cleared late, after accelerator self-test. A panic/hang in any post-attach publication step intentionally parks the next boot; verify every step is non-blocking and failure-safe.
- `nmx_bus_remove_device()` logs detach refusal but continues removal. If a child refuses detach, the subsequent deletion path may leave an inconsistent driver/device state. Inspect before changing unload or shutdown behavior.
- `scripts/install.test.sh` is non-reproducible in this checkout because its firmware source path is absolute. Fix separately before relying on the install test as a release gate.

## Current state

No code fix applied. Safe next action: reproduce the actual unbootable symptom on target hardware or provide the boot/panic log. Without that evidence, changing attach order or boot-guard behavior would be guessing.
