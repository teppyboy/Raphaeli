# Sequoia/Tahoe Build Products Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build target-specific x86_64 Raphaeli kexts and package them under one `target/Sequoia` / `target/Tahoe` release tree, with EFI-only target selection.

**Architecture:** Keep common AMDGPU/DRM/runtime objects shared. Build the accelerator lane with target-specific compile definitions and headers, following upstream `NM_TAHOE` forwarding behavior. Package both bundles under one release directory; `oc-install.py` selects one from explicit `--target` or mounted `--system-root`, never the host OS.

**Tech Stack:** Bash 3.2-compatible scripts, Python 3 stdlib, plistlib, clang/xcrun, MacKernelSDK, OpenCore Kernel/Add plist format.

**Spec:** `docs/superpowers/specs/2026-10-18-sequoia-tahoe-builds-design.md`

## Global Constraints

- Target selector values are exactly `sequoia`, `tahoe`, `all`.
- Runtime architecture is `x86_64`.
- MacKernelSDK revision is `3f750085caa17ec3a7880f11c11bf4f48cd6a164`.
- EFI tooling never calls host `sw_vers`.
- `--system-root` reads `System/Library/CoreServices/SystemVersion.plist`.
- ProductVersion 15.x maps to Sequoia; 26.x maps to Tahoe.
- Sequoia bounds are `MinKernel 24.0.0`, `MaxKernel 24.99.99`.
- Tahoe bounds are `MinKernel 25.0.0`, `MaxKernel 25.99.99`.
- One selected bundle is copied to `EFI/OC/Kexts/Raphaeli.kext`.
- No system installer runs on the development host.
- Existing unknown-selector, opt-in, firmware, and boot-guard semantics remain unchanged.

## Review Focus

- Missing target selection must fail before config/EFI mutation — test in Task 1.
- Unsupported ProductVersion must fail before mutation — test in Task 1.
- Existing EFI entry must be refreshed to the selected target bounds without duplicate entries — test in Task 2.
- `--target all` must package both bundles but never stage both into one EFI — test in Task 3.
- A Tahoe build must enable the forwarding layer rather than silently reuse Sequoia private ABI — test/build assertion in Task 4.

---

### Task 1: Add target resolution to the EFI tool

**Files:**
- Modify: `scripts/oc-install.py` argument parsing, source resolution, and `action_add()`.
- Test: `scripts/oc-install.test.sh` or a new focused Python fixture under `scripts/tests/`.

**Interfaces:**
- Produces `resolve_target(explicit: str, system_root: str, package_root: str) -> TargetInfo`.
- `TargetInfo` contains target name, source bundle path, Darwin min/max bounds.

- [ ] **Step 1: Write failing tests**

Add fixtures for:

```text
--target sequoia -> target/Sequoia/Raphaeli.kext
--target tahoe -> target/Tahoe/Raphaeli.kext
--system-root/System/Library/CoreServices/SystemVersion.plist ProductVersion=15.7 -> Sequoia
--system-root/... ProductVersion=26.6 -> Tahoe
missing target and no system root -> actionable failure
ProductVersion=14.0 or 27.0 -> unsupported failure
```

Assert no config or EFI copy occurs on failure.

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```sh
python3 -m unittest scripts/tests/oc_install_target_test.py
```

Expected: target resolver missing or current tool chooses the single default bundle.

- [ ] **Step 3: Implement target resolution**

Add target metadata and resolution using only explicit input or mounted `SYS_ROOT`. Do not invoke `sw_vers`. Make `--kext-src` remain an explicit override; when present, validate it as a single bundle and use explicit/default bounds only when target is known.

- [ ] **Step 4: Update `action_add()`**

Resolve target before config backup, validate selected bundle, copy it only after all checks pass, and create/update the entry with selected `MinKernel`/`MaxKernel`.

- [ ] **Step 5: Run tests**

Run:

```sh
python3 -m unittest scripts/tests/oc_install_target_test.py
./scripts/oc-install.test.sh
```

Expected: all target-selection and existing OC tests pass.

- [ ] **Step 6: Commit**

```sh
git add scripts/oc-install.py scripts/tests/oc_install_target_test.py scripts/oc-install.test.sh
git commit -m "feat: select kext by target macOS"
```

### Task 2: Add target-specific kext metadata and staging behavior

**Files:**
- Modify: `Raphaeli/Info.plist` generation/stamping path or add a target metadata helper used by link/package scripts.
- Modify: `scripts/oc-install.py` status/remove paths.
- Test: target-aware OC fixtures.

**Interfaces:**
- Produces target-specific bundle metadata with `CFBundleName` unchanged as `Raphaeli` and selected kernel bounds carried by the OC entry.

- [ ] **Step 1: Write failing tests**

Assert:

```text
existing Raphaeli entry gets selected MinKernel/MaxKernel refreshed
--status reports selected target
--remove removes only the staged single Raphaeli.kext
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```sh
python3 -m unittest scripts/tests/oc_install_target_test.py
```

Expected: current entry keeps `MinKernel 23.4.0` and empty `MaxKernel`.

- [ ] **Step 3: Implement minimal metadata refresh**

Update existing entries during `--add`, preserving unrelated fields and avoiding duplicate entries. Include selected target and bounds in status output.

- [ ] **Step 4: Run tests**

Run:

```sh
python3 -m unittest scripts/tests/oc_install_target_test.py
./scripts/oc-install.test.sh
```

- [ ] **Step 5: Commit**

```sh
git add scripts/oc-install.py scripts/tests/oc_install_target_test.py scripts/oc-install.test.sh
 git commit -m "feat: bound OpenCore entry by target kernel"
```

### Task 3: Make packaging produce `target/Sequoia` and `target/Tahoe`

**Files:**
- Modify: `scripts/package.sh`.
- Modify: `scripts/make-pkg.sh` only if target package inputs need explicit selection.
- Test: new `scripts/tests/package_target_test.sh` or shell fixture.
- Docs: `INSTALL.md` generation inside `scripts/package.sh`.

**Interfaces:**
- `package.sh --target sequoia` packages one selected kext.
- `package.sh --target tahoe` packages one selected kext.
- `package.sh --target all` packages both under `target/Sequoia/Raphaeli.kext` and `target/Tahoe/Raphaeli.kext`.

- [ ] **Step 1: Write failing packaging fixture**

Create fake `out/target/Sequoia/Raphaeli.kext` and `out/target/Tahoe/Raphaeli.kext`, fake userspace/firmware inputs, run each selector, and assert archive paths.

- [ ] **Step 2: Run fixture and verify failure**

Run:

```sh
./scripts/tests/package_target_test.sh
```

Expected: current script rejects `--target` or places only one `kext/` bundle.

- [ ] **Step 3: Implement selector and layout**

Parse `--target` without breaking existing version/output arguments. Stage selected bundles under `target/Sequoia` / `target/Tahoe`; for `all`, require both inputs and stage both. Keep firmware/userspace shared once.

- [ ] **Step 4: Update generated install instructions**

Document explicit EFI usage:

```sh
python3 tools/oc-install.py /path/to/EFI --add --target sequoia
python3 tools/oc-install.py /path/to/EFI --add --target tahoe
```

Document `--system-root` for mounted target volumes. Do not suggest host-version detection.

- [ ] **Step 5: Run tests**

Run:

```sh
./scripts/tests/package_target_test.sh
python3 -m unittest scripts/tests/oc-install_target_test.py
```

- [ ] **Step 6: Commit**

```sh
git add scripts/package.sh scripts/make-pkg.sh scripts/tests/package_target_test.sh
 git commit -m "feat: package target-specific kexts"
```

### Task 4: Add target-aware compile/link path

**Files:**
- Modify: `scripts/build.sh`, `scripts/rt.sh`, `scripts/link.sh`, and compiler wrappers as needed.
- Modify: `Raphaeli/Kernel/nmx_accel.h` / accelerator lane to consume target defines and Tahoe forwarding headers.
- Create: target-specific generated/header location under ignored `research/` or `out/`; do not commit generated private ABI blobs.
- Test: build-script argument tests and static command assertions.

**Interfaces:**
- Every script accepts `--target sequoia|tahoe|all`.
- Tahoe compile passes `-DNM_TAHOE` or an equivalent Raphaeli-specific define to accelerator sources.
- Sequoia compile omits Tahoe forwarding behavior.

- [ ] **Step 1: Write failing command-shape tests**

Assert mocked compiler invocations contain:

```text
Sequoia: no Tahoe define
Tahoe: -DNM_TAHOE
all: both target output directories
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```sh
./scripts/tests/target_build_args_test.sh
```

Expected: scripts reject target arguments or produce one shared output.

- [ ] **Step 3: Implement target routing**

Keep common object outputs isolated per target to prevent stale ABI objects from crossing builds. Use upstream `NM_TAHOE` pattern as the reference. Do not claim Tahoe support until Tahoe private headers/forwarding generation are available and compile.

- [ ] **Step 4: Run static/build checks**

Run:

```sh
./scripts/tests/target_build_args_test.sh
bash -n scripts/build.sh scripts/rt.sh scripts/link.sh scripts/package.sh
```

Then run selected target builds where source/KDK inputs exist.

- [ ] **Step 5: Commit**

```sh
git add scripts/build.sh scripts/rt.sh scripts/link.sh scripts/package.sh Raphaeli/Kernel
 git commit -m "feat: build Sequoia and Tahoe targets"
```

### Task 5: Full verification and report

**Files:**
- Modify: `docs/reports/sequoia-tahoe-static-audit.md`.
- Create: `docs/reports/sequoia-tahoe-builds.md`.

- [ ] **Step 1: Run host tests**

```sh
./scripts/oc-install.test.sh
python3 -m unittest scripts/tests/oc_stage_graphics_test.py scripts/tests/oc_install_target_test.py
./scripts/tests/package_target_test.sh
```

- [ ] **Step 2: Run build counts**

For each available target, require complete source counts and x86_64 Mach-O output.

- [ ] **Step 3: Inspect package**

```sh
unzip -l dist/Raphaeli-*-x86_64.zip
pkgutil --payload-files dist/Raphaeli-*-x86_64.pkg
```

Confirm one package tree contains both target bundles only when `--target all` is used.

- [ ] **Step 4: Record unresolved gates**

Document exact-KC OpenCore prelink status per target and mark hardware checks unverified where not run.
