# Raphaeli — AMD Radeon 780M (gfx1103) macOS driver

Kernel driver (XNU kext) bringing AMD Phoenix APUs up on macOS: an `amdgpu`-based
kernel/DRM port with a real display path (DCN), an IOFramebuffer, and an
IOAcceleratorFamily2 glue layer — plus Mesa RADV userspace for Vulkan.

```
Metal apps → Metal plugin → AIR→SPIR-V (metal2vulkan) → RADV → libdrm → Raphaeli.kext (amdgpu port) → 780M
```

- **Status:** builds and links end-to-end on the dev host; not yet validated on hardware.
- **Layout:** `Raphaeli/` (kext sources) · `kpi/` + `deps/` (pinned submodules) · `scripts/` (single build entry) · `patches/` · `docs/` (design + reports) · `dist/` (release zips, gitignored).
- **Design & bring-up:** [docs/DESIGN.md](docs/DESIGN.md) — full architecture, bring-up sequence, limits, legal gates.
- **Agents:** see [AGENTS.md](AGENTS.md) for build/test commands and working conventions.

Install routes: OpenCore (`tools/oc-install.py`, black-screen-safe) or direct
kextload (`scripts/install.sh`); userspace + firmware ships as a native `.pkg`
(`scripts/make-pkg.sh`); a RecoveryOS installer covers blind-machine setups
(`scripts/recovery-install.sh`). Everything is opt-in via the `raphaeli-amd=1`
boot-arg.
