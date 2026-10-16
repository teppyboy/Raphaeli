# AGENTS.md

Guidance for AI coding agents working on Raphaeli.

## What this project is

A macOS kernel driver for AMD Phoenix APUs (gfx1103 family): the `amdgpu` port
(FreeBSD drm-kmod LinuxKPI → XNU), a DCN display path, an IOFramebuffer
(`RaphaeliFB`), IOAcceleratorFamily2 glue (`RaphaeliAccel`), and Mesa RADV
userspace for Vulkan. Universal across AMD Phoenix device IDs — the project
currently develops and tests against the one Phoenix SKU available: Radeon
780M (PCI `0x15bf`), which is the only personality match in `Info.plist`
until more SKUs are validated.

Dev host = x86_64 macOS 15.7.8 Hackintosh, AMFI + Secure Boot disabled (no
kext signing needed), SIP custom. The target Phoenix machine is elsewhere —
hardware behavior is unverified here.

## Build and validate (dev host, run from repo root)

```sh
./scripts/build.sh              # 900 kernel/DRM sources -> obj/ (must be 900/900)
./scripts/rt.sh                 # 81 runtime sources -> lkobj/, srcobj/, xnuobj/ (81/81)
./scripts/link.sh out-disp      # link out-disp/Raphaeli.kext
kmutil inspect -V tb -p "$PWD/out-disp/Raphaeli.kext"   # rc=0 = sanity
./scripts/install.test.sh ./scripts/oc-install.test.sh ./scripts/fw-bundle.test.sh   # host tests
clang++ -std=c++17 -I Raphaeli/Kernel scripts/tests/nmx_fb_edid_test.cpp && ./a.out
```

- Long compiles exceed tool timeouts: run `nohup <cmd> > /tmp/x.log 2>&1 &` then poll.
- `scripts/kpi-init.sh` initializes submodules and applies `patches/*.patch`;
  `build.sh` runs it automatically. Don't edit anything under `kpi/` or `deps/`
  directly — those trees are pinned upstream + patches.
- Only `link.sh out` (root:wheel) or `link.sh out-disp` (user-owned) are valid
  kext outputs. kmutil silently classifies user-owned kexts as "codeless":
  ownership `root:wheel` is the real discriminator, not signatures. Use
  absolute `-p` paths — relative ones silently fail.
- Never run `installer` on the dev host; validate `.pkg`s by inspection only
  (`pkgutil --payload-files`).

## Layout map

| Path | Contents |
|---|---|
| `Raphaeli/Kernel/` | IOKit C++ glue (`nmx_kext.cpp` entry, `nmx_fb.cpp` display, `nmx_accel*.cpp` accel) |
| `Raphaeli/Compat/` | FreeBSD-on-XNU compatibility layer (`src/`, `include/`) |
| `Raphaeli/Override/` | LinuxKPI forks/replacements; `src/nmx_accel_bridge.c` (ring/fence), `src/nmx_dm_bridge.c` (DCN modeset) |
| `Raphaeli/Firmware/` | firmware staging (`stage.sh` = blob-name source of truth) |
| `scripts/` | every build/tool script; paths derive `$(dirname "$0")/..` |
| `kpi/` | submodules: drm-kmod, freebsd-src (kernel KPI) |
| `deps/` | submodules: mesa, libdrm, metal2vulkan (userspace build pins) |
| `patches/` | mesa-macos, libdrm-macos (+ freebsd-src if ever needed) |
| `docs/` | `DESIGN.md` + `docs/reports/` (one report per work lane) |
| `research/`, `work-*/`, `obj*/`, `out*/`, `dist/`, `firmware/` | gitignored scratch/build trees |

## Hard design constraints (do not violate)

1. **The driver attaches in every boot environment, including RecoveryOS** —
   on target Phoenix machines recovery is blind without it. Never add a
   recovery opt-out. Failed-attach safety is handled by the
   `raphaeli-gpu-attaching` NVRAM park marker, not by refusing to attach.
2. **Unknown IOAccel selectors return `kIOReturnUnsupported`** — always. The
   family vtables are version-sensitive; guessing breaks WindowServer.
3. **All failure paths must be non-panicking.** A wrong GPU address can fault a
   ring; never call amdgpu internals with unvalidated values.
4. **Boot-arg opt-in:** the kext stays inert without `raphaeli-amd=1`.
   Keep OC injection black-screen-safe (no boot-arg added by default).
5. **No kext signing** (AMFI off) — keep `-source_version`, don't add signing
   steps. Bundles must end up `root:wheel` for kmutil to treat them as real.
6. **Bash scripts must run under bash 3.2** (RecoveryOS env) — no arrays,
   no `coproc`, only tools Recovery ships.
7. **Adding a new Phoenix SKU** = extend `IOPCIPrimaryMatch` in
   `Raphaeli/Info.plist` + verify the firmware set covers it (IP discovery
   table revisions can differ per SKU). Never widen the match speculatively —
   only IDs whose firmware/bring-up path has been checked.

## Code style

- Kernel IOKit side: C++ (Apple kext style), 4-space indent, tabs in the
  FreeBSD-derived C code, `nmx_` prefix for symbols.
- Boundary pattern: IOKit TUs never include amdgpu headers; they call
  `extern "C"` bridges declared in `Raphaeli/Kernel/*.h` and implemented in
  `Raphaeli/Override/src/*.c` (see `nmx_accel_bridge`, `nmx_dm_bridge`).
- Every lane writes a report to `docs/reports/<lane>.md` before committing.
- Commit identity: `tretrauit <tretrauit@gmail.com>`; short imperative subjects.
- Firmware blob names come from `Raphaeli/Firmware/stage.sh` — treat it as the
  census source of truth.

## Testing

- Host tests: `scripts/*.test.sh` + `scripts/tests/*.cpp` (host clang++, no
  system changes). Run after any change to install/packaging/firmware/EDID.
- `build.sh` + `rt.sh` must stay green (900/900, 81/81) before committing.
- `kmutil inspect -V tb -p <absolute kext path>` must exit 0.
- Hardware-gated checks (selftest boot-args, WindowServer open, panel light-up)
  can only run on target Phoenix hardware — mark unverified, don't fake.

## Reproducibility

- All build inputs are pinned submodules (`kpi/`, `deps/`, `shallow = true`).
  Fresh machine: `git clone --recurse-submodules --shallow-submodules --depth 1`
  then `scripts/kpi-init.sh`.
- Never commit build artifacts: `out*/`, `obj*/`, `dist/`, `work-*/`,
  `research/`, `firmware/` are gitignored.
