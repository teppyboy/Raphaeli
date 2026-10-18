# Sequoia/Tahoe Build Products Design

## Goal

Produce OS-specific x86_64 Raphaeli kexts for macOS Sequoia and Tahoe, with one combined release option.

## User-facing target selector

Build commands accept exactly:

```text
--target sequoia
--target tahoe
--target all
```

`all` builds/packages both variants. No `both` spelling.

## Artifact layout

The release has one Raphaeli package directory containing OS-targeted subdirectories:

```text
dist/Raphaeli-<hash>-x86_64/
├── target/
│   ├── Sequoia/Raphaeli.kext/
│   └── Tahoe/Raphaeli.kext/
├── firmware/
├── usr/
└── tools/
```

Do not place variants inside one `Raphaeli.kext/Tahoe/` bundle. macOS loads one `Contents/MacOS/<CFBundleExecutable>` and does not select nested variant executables.

Build scratch outputs:

```text
out/target/Sequoia/Raphaeli.kext/
out/target/Tahoe/Raphaeli.kext/
```

## EFI installer selection

`oc-install.py` operates on an EFI folder, never on the agent host's macOS version.

Selection priority for `--add`:

1. Explicit `--target sequoia|tahoe`.
2. `--system-root <mounted-system-volume>`: parse `<root>/System/Library/CoreServices/SystemVersion.plist` and map ProductVersion 15.x to Sequoia, 26.x to Tahoe.
3. Otherwise fail with an actionable message; never call host `sw_vers`.

The package tools use `--kext-src` as an explicit single-bundle override. With a combined package and no override, `oc-install.py` resolves its sibling package root and selects `target/Sequoia/Raphaeli.kext` or `target/Tahoe/Raphaeli.kext` from explicit target/system-root input.

After selection, copy exactly one bundle to:

```text
EFI/OC/Kexts/Raphaeli.kext/
```

The EFI receives one `Kernel -> Add` entry. Unsupported ProductVersion values and missing target selection fail before mutating config or EFI files.

## Runtime selection bounds

The selected bundle/config entry uses:

```text
Sequoia: MinKernel 24.0.0, MaxKernel 24.99.99
Tahoe:   MinKernel 25.0.0, MaxKernel 25.99.99
```

The scripts must not enable both variants for the same target.

## SDK and private ABI

Use `research/MacKernelSDK` commit `3f750085caa17ec3a7880f11c11bf4f48cd6a164` for common public kernel/IOKit headers and kmod libraries.

Use OS-specific accelerator ABI definitions/build flags. The latest `research/nvidia-macos-driver` commit `637282334617d27bccf8aa2448497c0f19465dc8` confirms a Tahoe path:

- `build/accel_build.sh` uses `NM_TAHOE=1` for macOS 26.
- `build/accel_build_all.sh` builds separate macOS 15 and macOS 26 outputs.
- `kexts/NVRM/accel/gen_tahoe_fwd.py` generates Tahoe forwarding methods because Tahoe made 27 IOAcceleratorFamily2 methods private and retyped 7.
- The upstream design keeps separate accelerator binaries while sharing the remaining kexts.

Raphaeli must mirror this pattern: common core, separate Sequoia/Tahoe accelerator translation units/headers or generated forwarding layer. Current Sequoia-only fixed `populateAccelConfig()` offsets and private vtables must not be silently reused as Tahoe ABI.

## Build interface

Extend `scripts/build.sh`, `scripts/rt.sh`, `scripts/link.sh`, and `scripts/package.sh` with the selector. Existing no-argument behavior remains the current single-target development path only if it is explicitly documented; release packaging requires `--target`.

Expected examples:

```sh
./scripts/build.sh --target sequoia
./scripts/rt.sh --target sequoia
./scripts/link.sh --target sequoia
./scripts/package.sh --target sequoia

./scripts/package.sh --target all
```

## Verification

Static/build gates:

- Each selected target produces an x86_64 Mach-O kext.
- `build.sh` and `rt.sh` report complete counts for each target.
- Each kext has target-specific `MinKernel`/`MaxKernel` metadata or installer-generated OpenCore entry bounds.
- OpenCore prelink checks run against matching Sequoia/Tahoe kernel collections and reject cross-target dependencies.
- Existing host tests remain green.

Hardware gates remain separate and unverified until the Lenovo Phoenix target boots each variant.

## Non-goals

- No universal accelerator-enabled binary claiming ABI compatibility without target-KC prelink evidence.
- No automatic runtime selection inside a single kext bundle.
- No speculative widening of Phoenix PCI IDs.
- No installer execution on the Apple Silicon development host.
