# Raphaeli

An experimental AMD Phoenix (RDNA 3) GPU driver for macOS.

> [!WARNING]
> This project is vibe-coded entirely, bloated/unreadable codebase, slow maintenance and updates are expected. Use at your own risk.

### How does this driver work?

Kind of the same architecture as [nullmoth/nvidia-macos-driver](https://github.com/nullmoth/nvidia-macos-driver), tl;dr see below:

```
Metal apps → Metal plugin → AIR→SPIR-V (metal2vulkan) → RADV → libdrm → Raphaeli.kext (amdgpu port) → GPU
```

## Installation

TODO

## Development

This driver is written entirely by LLMs, so you should use a LLM to develop instead. Still, if you're interested then see [docs/DESIGN.md](docs/DESIGN.md)

### Build and package

The build requires macOS Xcode Command Line Tools, `meson`, `ninja`, and
`glslangValidator` (from the glslang package). Install the Apple tools with
`xcode-select --install`; install the other tools through the host package
manager.

AMD firmware is required but is not vendored in this repository. Obtain a
matching `linux-firmware/amdgpu` directory separately, then run the build and
package as two separate invocations:

```sh
RAPHAELI_FW_SRC=/path/to/linux-firmware/amdgpu ./scripts/build.sh && ./scripts/package.sh
```

`build.sh` stages the external firmware and produces the kext/userspace
artifacts; `package.sh` validates those outputs and creates the release.

To build both Sequoia and Tahoe bundles from one source compile:

```sh
RAPHAELI_FW_SRC=/path/to/linux-firmware/amdgpu \
RAPHAELI_OC_KEXTINJECT=/path/to/KextInject \
RAPHAELI_TAHOE_KC=/path/to/tahoe-recovery/BootKernelExtensions.kc \
RAPHAELI_TAHOE_KDK_EXT=/path/to/KDK/System/Library/Extensions \
./scripts/build-all.sh          # or: all | sequoia | tahoe
```

`build-all.sh` writes `out/target/Sequoia/Raphaeli.kext` and
`out/target/Tahoe/Raphaeli.kext`; `out-disp/` is not touched. The Tahoe bundle
is removed and the script fails unless the OpenCore injection gate
(`check-oc-injection.sh`) passes against the Tahoe Recovery KC. See
[docs/reports/build-all.md](docs/reports/build-all.md). Package a target with
`RAPHAELI_KEXT=out/target/Sequoia/Raphaeli.kext ./scripts/package.sh`.

## License

[GNU GPLv3](./LICENSE)
