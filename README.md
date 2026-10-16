# Raphaeli

An experimental AMD Phoenix (RDNA 3) GPU driver for macOS.

> [!WARNING]
> This project is vibe-coded entirely, bloated/unreadable codebase, slow maintenance and updates are expected. Use at your own risk.

### How does this driver work?

Kind of the architecture as [nullmoth/nvidia-macos-driver](https://github.com/nullmoth/nvidia-macos-driver), tl;dr is below:

```
Metal apps → Metal plugin → AIR→SPIR-V (metal2vulkan) → RADV → libdrm → Raphaeli.kext (amdgpu port) → GPU
```

## Installation

TODO

## Development

This driver is written entirely by LLMs, so you should use a LLM to develop instead. Still, if you're interested then see [docs/DESIGN.md](docs/DESIGN.md)

## License

[GNU GPLv3](./LICENSE)
