# Integration lane report: display + accel wired into one Raphaeli.kext

Commits: `d5e7900` (main wiring) + `2fd5832` (follow-up: tests/ move, rt.sh display glob, package.sh KEXT override). Dist: `dist/Raphaeli-1.0.1-x86_64.zip` (11.2 MB, built from the fresh `xkpi/out-disp` link).

## What was wired

1. **kext/Info.plist** (`plutil -lint` OK):
   - `RaphaeliFB` — IOClass RaphaeliFB, IOProviderClass IOPCIDevice, IOProbeScore 1000.
     **Deviation from fb-display.md, deliberate:** the report suggested copying the main personality's
     vendor-wide match, but RaphaeliFB has no probe()-level opt-in (only BAR0 + scanout gates in
     start()), so a vendor-wide personality would bind any AMD/Intel display-class GPU on hosts where
     the user never opted in — including this dev host. The personality is narrowed to the primary
     target device: `IOPCIPrimaryMatch 0x000015bf&0xffffffff` (780M) + class 03 match. Inert anywhere
     else. Widening it needs an opt-in/probe gate in nmx_fb.cpp first (fb lane).
   - `RaphaeliAccel` (0x00001002) + `RaphaeliAccelIntel` (0x00008086) — IOClass RaphaeliAccel, class
     03 match, `IOMatchCategory IOAccelerator` (lets Raphaeli + RaphaeliAccel share one PCI function),
     IOProbeScore 100. Vendor-wide matching is safe here: accel `start()` declines unless the provider
     carries `nmxgpu-claimed`, which only the main Raphaeli service sets after a successful attach.
     No IOUserClientClass keys (family's `IOGraphicsAccelerator2::newUserClient` creates all client
     types; per accel-family.md).
   - `OSBundleLibraries` += `com.apple.iokit.IOAcceleratorFamily2` 2.0.0 (kmutil accepted without
     an explicit IOSurface entry).
2. **link.sh**: `xnuobj/nmx_accel.o xnuobj/nmx_accel_uc.o` added to the object list (scanout objects
   were already globbed via `srcobj/*.o`).
3. **xnu/nmx_kext.cpp**:
   - `nmx_scanout_selftest()` call inserted right after `nmx_port_start()` succeeds inside the
     `g_started` block (scanout.md step 8); self-inert — returns 0 unless boot-arg
     `raphaeli-scanout-test=1`. Extern declared file-top.
   - Legacy bridge dropped per fb-display.md: `nmx_fb_publish`/`nmx_fb_unpublish` declarations,
     the `fb_` member and all three call sites removed from nmx_kext.cpp; the two no-op stub
     functions (plus their "retired bridge path" comment block) removed from nmx_fb.cpp — exactly
     the two-function deletion the task allowed.
4. **xnu/nmx_fb_edid_test.cpp → xkpi/tests/nmx_fb_edid_test.cpp** (per parent guidance): the
   host-only self-check (assert.h) lived inside xnu/, which the kernel-flag build glob sweeps.
   Moved out of the glob entirely; the APPLE guard from the first pass reverted — the file is the
   fb lane's original, with only the run command in the header comment updated
   (`clang++ -std=c++17 -I xnu tests/nmx_fb_edid_test.cpp && ./a.out`). Host run passes.
5. **rt.sh now builds `override/display/*.c`** — real gap found during follow-up: NO build loop
   compiled `nmx_scanout_selftest.c` (the scanout lane's `srcobj/nmx_scanout_selftest.o` was
   hand-built; any `rt.sh` run wiped srcobj and silently dropped it). First kmutil auxKC attempt
   failed at bind with `Failed to bind '_nmx_scanout_selftest' in 'me.tretrauit.raphaeli'` —
   exactly the failure class the KDK link would have shipped. Fixed by adding the glob to rt.sh's
   ccsrc loop (runtime sources: 78, failed: 0; `_nmx_scanout_selftest` now defined in the binary).
6. **package.sh**: `RAPHAELI_KEXT=<dir>` override for the kext source (needed when
   `xkpi/out/Raphaeli.kext` is root:wheel and a fresh user-owned link lives elsewhere).

## Build + validation evidence

| check | result |
|---|---|
| `./build.sh` | sources: 900, compiled: 900, failed: 0 |
| `./rt.sh` | runtime sources: 78, failed: 0 (incl. override/display after the follow-up; 77 before it, edid test out of the glob) |
| `./link.sh out-disp` | Raphaeli d4a4305b, 10,977,304 B; only benign libkmod version warnings; `nm -u` shows 0 undefined scanout symbols |
| `plutil -lint` (source + bundled plist) | OK |
| `kmutil inspect -V tb -p xkpi/out-disp/Raphaeli.kext` | parses cleanly (INSPECT_OK) |
| `otool -l` | LC_UUID present |
| `nm -gU` | 16 gMetaClass-family symbols incl. `__ZN10RaphaeliFB10gMetaClassE`, `__ZN13RaphaeliAccel10gMetaClassE` |
| `strings` stale check | 0 hits for NMXGPU/NMXNPU; RaphaeliFB/RaphaeliAccel strings present |

## auxKC status (deferred, decision (b); ready-to-run recipe below)

Two host-specific findings from the attempts:

1. **kmutil needs an ABSOLUTE `-p` path.** With a relative path (`-p out/Raphaeli.kext`, cwd = xkpi)
   the kext is silently classified as codeless → `KMErrorDomain Code=31 "No binaries or codeless
   kexts were provided"`. The same command with `$PWD/out/Raphaeli.kext` got past classification and
   reached real symbol binding (it then failed only on the then-undefined `_nmx_scanout_selftest`,
   fixed since). auxkc-diagnosis.md's ownership rule stands, but relative-path classification is an
   additional silent-drop pitfall.
2. Ownership: `xkpi/out/Raphaeli.kext` was chowned root:wheel externally mid-session, which blocks
   relinking by the build user (ld can't overwrite; rm denied; no passwordless sudo). Current fresh
   link is `xkpi/out-disp/Raphaeli.kext` (yuuki-owned, selftest bound).

One-paste (a) sequence for anyone with sudo (relink + proven auxKC proof):

```
cd Raphaeli/xkpi
sudo rm -rf out/Raphaeli.kext && ./link.sh out
sudo chown -R root:wheel out/Raphaeli.kext && sudo chmod -R 755 out/Raphaeli.kext
kmutil create -a x86_64 -n aux -x -p "$PWD/out/Raphaeli.kext" --no-authentication \
  -A /tmp/raphaeli-auxkc-disp -B /System/Library/KernelCollections/BootKernelExtensions.kc \
  -S /System/Library/KernelCollections/SystemKernelExtensions.kc \
  --kdk /Library/Developer/KDKs/KDK_15.7.8_24G824.kdk
strings /tmp/raphaeli-auxkc-disp | grep -c RaphaeliFB   # >0 proves the binary is inside
```

Note: every `link.sh` run resets ownership — always chown after relinking, before any kmutil run.
install.sh/oc-install.py already do this on the target machine at install time.

## Hardware bring-up checklist (780M machine)

Safe mode first: OpenCore `--add` (inert) → boot → then `--enable` (raphaeli-amd=1). Recovery at any
point: `--disable` (or Enabled=false in config.plist); with no boot-arg nothing matches/binds.

Boot log (`sudo dmesg` / `log show --last 5m --predicate 'senderImagePath contains "Raphaeli"'`), in order:

1. `Raphaeli GPU: driving 1002:15bf` — main service claimed the GPU. Before this, expect nothing:
   every personality is inert without the opt-in.
2. `Raphaeli display: ` messages from RaphaeliFB::start — BAR0 audit + `nmx_scanout_alloc`. Failure
   strings to expect early: "no usable MMIO BAR0 …" or "scanout allocation failed/KERN_NO_SPACE" —
   firmware framebuffer keeps the screen; not a hang. (KERN_NO_SPACE = no contiguous ≥8 MB run under
   4 GB post-boot fragmentation; known v0 limit, v1 moves scanout to VRAM.)
3. With `raphaeli-scanout-test=1` added: `scanout selftest: PASS` (or FAIL + reason) right after the
   driver layer starts; inert without the boot-arg.
4. RaphaeliAccel: IOKit registry should show RaphaeliAccel under the same IOPCIDevice only AFTER
   "driving 1002:15bf" (needs `nmxgpu-claimed`). If WindowServer opens IOAccelerationUserClient:
   opens + config queries work; buffer/resource creation refuses honestly (no VRAM/GART bridge yet —
   accel-family.md risk 1). No Metal plugin is armed (deliberate; Metal stalls otherwise).
5. RaphaeliFB success sign: WindowServer binds, console text lights through the scanout buffer at
   the VBIOS-EDID mode (fallback 1920x1080@60 if EDID scan found nothing sane — check the log line).

Expected early failures that are NOT bugs: 0 Hz refresh in Displays if kIODetailedTimingValid is
missing (implemented, but watch), scanout visible garbage (WC zeroing bug — report, don't reboot-loop),
sleep/wake (setPowerState path untested on hardware).

Kill-switch: `sudo kmutil unload` may refuse while device nodes are open (by design); recovery is
always the OC `--disable` reboot.
