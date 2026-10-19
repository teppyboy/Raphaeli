# Sequoia/Tahoe static compatibility audit

Date: 2026-10-18

## Request

Assess whether one Raphaeli x86_64 kext build can target both macOS Sequoia (Darwin 24.x) and Tahoe (Darwin 25.x) using MacKernelSDK, without full hardware testing.

## Evidence

- MacKernelSDK fetched at `research/MacKernelSDK`, commit `3f750085caa17ec3a7880f11c11bf4f48cd6a164`.
- MacKernelSDK is based on the macOS 11 SDK and adds compatibility/private headers. It does not contain `IOGraphicsAccelerator2`, `IOAccelTask`, or the other reconstructed IOAcceleratorFamily2 private classes used by Raphaeli.
- MacKernelSDK itself documents broad kernel-header targeting, not a universal private graphics-family ABI. Its `IOPCIBridge.h` comments include Tahoe-specific layout extensions, proving some ABI details are OS-version-specific.
- `Raphaeli/Kernel/nmx_accel.h` imports reconstructed private accelerator headers from `research/nvidia-macos-driver` and explicitly describes them as Sequoia x86_64 layouts.
- `Raphaeli/Kernel/nmx_accel.cpp` writes fixed offsets in `populateAccelConfig()` and uses reconstructed factory/vtable declarations. These are unsafe to assume across Sequoia/Tahoe.
- OpenCore prelink experiments documented in `docs/reports/oc-vtable-reproduction.md` show graphics-family superclass vtables must come from the target's matching KC. A dependency binary from the other OS is not a valid universal solution.
- `Raphaeli/Info.plist` requests `IOGraphicsFamily 1.0.0b1` and `IOAcceleratorFamily2 2.0.0`, but the matching family binaries, UUIDs, and vtables remain target-KC-specific.
- Build scripts currently select the active Xcode `Kernel.framework` via `xcrun --sdk macosx`; they do not select MacKernelSDK or an OS-specific private accelerator ABI.

## Ranked static risks

1. **Critical — private accelerator ABI drift.** The IOAccel class declarations, vtable order, class sizes, selector numbers, and config offsets are not stabilized by MacKernelSDK. A single binary may inject on one OS and fail vtable patching or corrupt state on the other.
2. **Critical — `populateAccelConfig()` fixed offsets.** Offsets `0x00` through `0x64` are undocumented and described as Sequoia layout. Tahoe can interpret the writes differently.
3. **Critical — target KC dependencies.** OpenCore resolves superclass vtables from the active KC. Sequoia and Tahoe require exact-build graphics family dependencies; one `OSBundleLibraries` list cannot supply both private implementations.
4. **High — private superclass availability.** `IOFramebuffer` and IOAccelerator-derived classes need real matching family vtables. MacKernelSDK headers alone cannot provide those runtime vtables.
5. **Medium — SDK/header split.** MacKernelSDK can replace public Kernel.framework headers for common IOKit/KPI code, but this port also uses Apple-private/reconstructed declarations and private family link behavior.
6. **Medium — packaging/config.** A shared OpenCore config needs Darwin-version-bounded entries or separate kext products. `MinKernel`/`MaxKernel` must prevent a Sequoia-only accelerator binary from loading on Tahoe and vice versa.

## Recommendation

Do not claim one universal accelerator-enabled kext. Build two OS-specific products:

- `Raphaeli-Sequoia.kext`: Darwin 24.x, exact Sequoia graphics-family ABI/dependencies.
- `Raphaeli-Tahoe.kext`: Darwin 25.x, exact Tahoe graphics-family ABI/dependencies.

Share the AMDGPU/DRM/PCI/display C/C++ core. Isolate the IOAccel lane behind OS-specific translation units and reconstructed headers. Use MacKernelSDK for common public/kernel headers and kmod libraries, but retain per-OS private accelerator headers and per-OS OpenCore dependency staging.

If one product is mandatory, the safe version is a render-only/display-only kext that excludes `RaphaeliAccel` and other private IOAccel subclasses. That avoids the vtable/layout dependency but does not provide WindowServer acceleration.

## Proposed validation gates

1. Compile common core with MacKernelSDK headers.
2. Compile Sequoia accelerator lane against Sequoia reconstructed headers.
3. Compile Tahoe accelerator lane against Tahoe reconstructed headers.
4. Run OpenCore prelink tests against exact Sequoia and Tahoe KCs.
5. Require per-OS `MinKernel`/`MaxKernel` config entries.
6. Hardware boot remains mandatory for runtime validation; static analysis cannot verify GPU reset, firmware, DCN, or ring safety.
