# Dependency audit: research/nvidia-macos-driver

Scope: read-only audit of the `research/nvidia-macos-driver` reference tree against its upstream, plus the Raphaeli
references into it. No reset, merge, fast-forward, stash, or delete in either repository. No commit or push.

## Refs (exact, at audit time)

Raphaeli (`/Users/yuuki/Documents/tretrauit/code/Raphaeli`)
- Branch `main`, HEAD `b9a40c48c25812066be21c1e4e42b8d6bae7b53e` (`Rename AMD GPU park boot argument`).
- Worktree dirty: 28 entries (modified and untracked, pre-existing; not touched by this audit).
- Remotes: none inspected or fetched (Raphaeli fetch not part of this task).

research/nvidia-macos-driver
- Branch `main`, HEAD `b737dedc11fa4edbcb4abe8d51e94cebfed21ac6` (`Driver and Mac app 2.0.4`).
- `origin` = `https://github.com/nullmoth/nvidia-macos-driver`.
- `git fetch origin` succeeded (rc=0). `origin/main` = `47f818b11cef59acb480210afdf9065fdd44e356` (`Release 2.4.3`,
  2026-10-19).
- `HEAD...origin/main` = 0 local-only commits, 102 upstream-only commits. HEAD is strictly behind; no divergence.
- `git diff --stat HEAD origin/main`: 617 files, +9579 / -65437. Net deletion is large: upstream removed whole
  trees (including the `gpu-port/` vendored subtrees that exist as untracked files locally; see below).

## Dirty state of research/nvidia-macos-driver (preserved, not modified)

Tracked modifications (2):
- `AGENTS.md`: deletes the 6-line "No AI-written contributions / Notes for AI assistants" block.
- `CONTRIBUTING.md`: deletes the "No AI-written contributions" section.

Untracked directories (2, about 13,174 files total, 414 MB):
- `gpu-port/libdrm/` (3.3 MB).
- `gpu-port/mesa/` (411 MB).

These are not tracked at HEAD or at `origin/main` (`git ls-tree` on both shows no `gpu-port/libdrm` or `gpu-port/mesa`).
Preserved as-is. Do not clean them; they are the only copy of that vendored source in this checkout.

Note: the two deleted AI-policy sections are local edits, not upstream state. Upstream still contains them (checked
via `git show origin/main:AGENTS.md`-equivalent tree). Treat as an unreviewed local change; decide separately whether to
keep, discard, or restore.

## Relevant upstream changes (HEAD..origin/main)

Tahoe (macOS 26) and mapping-related commits in range:
- `e8031d7` Draw the macOS 26 icon and glass shaders again (2026-10-18).
- `27f6743` Audio: NMXAudio kext links into a macOS 26 collection (2026-10-16).
- `c8d03d8` The Mac app moves to 1401; this repository is the NVIDIA driver (2026-10-16).
- `2780e63` Serialise the kernel mapping table; `33276e8` and `f41434d` test the mapping table (2026-10-18).
- `fb122d0` Keep the bar bound on card mappings, not the framebuffer alone (2026-10-18).
- `3f117ab` NVRM: publish a per-generation GPU profile; `94811fc` Mac app: Map my GPU (experimental) (2026-10-15).
- `7dd3aeb` NVRMFB: run every scheduled callback one at a time (#295) (2026-10-19); the 2.4.3 fix.

Removed upstream (present at HEAD, absent at `origin/main`):
- `app/Sources/HardwareMap.swift`, `app/Sources/HardwareMapWorker.swift`.
- `tools/prove_tahoe_kmutil.sh`, `tools/test_tahoe_model_switch.py`, `tools/test_hardware_map.py`,
  `tools/hardware_map_tests/main.swift`, and about a dozen other `tools/test_*` scripts.
- `kexts/NVRM/accel/nmx/Info.plist`, `kexts/NVRM/accel/nmx_accel_names.h`.
- `gpu-port/xkpi/bsdcompat/include/ck_bitmap.h`; `vm/pmap.h` and `vm/vm_map.h` (trimmed).

Changed upstream in a Tahoe/accel-relevant way:
- `kexts/NVRM/accel/nvrm-accel.cpp` (+288 / -, largest accel delta), `kexts/NVRM/accel/nvaccel_stubs.h` (+7).
- `package/install.sh` (+210 / -, install-path rework; see the 2.4.2 / 2.4 install changes).
- `tools/test_nvrm_map_table.py` (+/-11).

Tahoe-tagged files at `origin/main` (unchanged path set vs HEAD except as above): `CHANGELOG.md`, `README.md`,
`build/accel_build.sh`, `build/accel_build_all.sh`, `kexts/NVRM/accel/gen_stubs.py`, `kexts/NVRM/accel/gen_tahoe_fwd.py`,
`kexts/NVRM/accel/nvaccel_stubs.h`, `kexts/NVRM/accel/nvrm-accel.cpp`, `kexts/NVRM/accel/tahoe_fwd.h`,
`package/install.sh`, `plugin/NVMTLObjects.m`, `tools/test_surface_alloc_bound.py`.

Mapping (kernel-side headers referenced by Raphaeli) at HEAD and `origin/main` are byte-identical:
- `kexts/NVRM/accel/re/IOGraphicsAccelerator2.h` (09597fb), `iofam/IOAccelEventMachineFast2.h` (d14bbf9),
  `iofam/IOAccelLegacyDisplayMachine.h` (916bf50), `iofam/IOAccelTask.h` (4e9102f), `iofam/IOAccelMemoryMap.h` (1e0c092),
  `iofam/IOAccelResource2.h` (92727bf), `tahoe_fwd.h` (6a1389c), `gen_tahoe_fwd.py` (d257396).
- So the IOAccel family headers that `Raphaeli/Kernel/nmx_accel.h` includes did not change upstream in range.

## Raphaeli references into research/

- `Raphaeli/Kernel/nmx_accel.h` includes six `research/nvidia-macos-driver/kexts/NVRM/accel/{re,iofam}/*.h` headers.
  Those headers are unchanged in range (above), so the include contract holds at `origin/main`.
- `Raphaeli/Kernel/nmx_accel.cpp` and `Raphaeli/Kernel/nmx_accel_uc.cpp` cite
  `kexts/NVRM/accel/nvaccel_stubs.h` and `nvrm-accel.cpp` in comments only. `nvaccel_stubs.h` and `nvrm-accel.cpp`
  both changed upstream: comment-level references only, no build break, but the cited behavior may have moved.
- `.gitignore` ignores `research/`; `Raphaeli/Firmware/README.md` points to `research/.../gpu-port` as a vendor-less
  reference (no build input).
- No Raphaeli code references the removed `HardwareMap*`, `prove_tahoe_kmutil.sh`, or `test_tahoe_model_switch.py`.

## Findings

1. Research clone is 102 commits behind; no local commits to lose. Fast-forward is safe but was not done (out of scope).
2. The untracked `gpu-port/libdrm` and `gpu-port/mesa` trees (about 414 MB) and the two local AI-policy deletions are
   the only local state. Upstream deletes the `gpu-port/xkpi` headers in range; the untracked trees do not come from
   upstream, so a fast-forward or hard reset would not remove them, but a `git clean` would. Do not run `git clean`.
3. Raphaeli's IOAccel include surface is stable across the upgrade. The `nvrm-accel.cpp` / `nvaccel_stubs.h`
   comment references are the only upgrade-sensitive touchpoints.
4. Raphaeli worktree: 28 dirty entries, owned by other lanes. Not touched.

## Recommended next steps (not executed)

- Decide the research-tree update separately: option A keep HEAD as pinned reference; option B fast-forward to
  `47f818b` after the untracked `gpu-port/*` and the two AI-policy edits are copied out or confirmed disposable.
- Re-check `nvrm-accel.cpp` and `nvaccel_stubs.h` comment references in `Raphaeli/Kernel/` if the reference moves.

## Refresh check (2026-10-22)

The reference and pinned build inputs were rechecked after the earlier audit; local work was preserved:

- `research/nvidia-macos-driver`: fetched `origin`; local HEAD remains `b737dedc11fa4edbcb4abe8d51e94cebfed21ac6`, `origin/main` remains `47f818b11cef59acb480210afdf9065fdd44e356` (102 commits ahead). `IOAccelTask.h` remains unchanged. The only large acceleration-source delta identified in the earlier relevant-file review is the NVIDIA-specific `nvrm-accel.cpp` (+278/-10); it changes surface synchronization/diagnostics and does not establish an AMD VM/task lifetime or IOAccel command contract. No merge or cherry-pick was made. The two modified policy files and untracked `gpu-port/*` remain untouched.
- `kpi/drm-kmod`: fetched `origin/master`; pin `c16de0f9fa84f70b9551f69fde837a7f3a73c0e9` equals upstream (`0` commits behind).
- `kpi/freebsd-src`: fetched `origin/main`; pin `f4fe4c3d17f9bb523981b88a01d7c0f0c0f00c36` is 207 commits behind. The queried LinuxKPI slab/kobject interfaces had no matching targeted changes in the fetched range; no vendor tree was updated.
- `deps/libdrm`: pinned `b97cbde15c5c3abfe44d78e8f57139e50f612fec` equals its fetched upstream `origin/main`; local macOS port modifications remain present.
- `deps/mesa`: pinned `d44453ce07ba5e1e6b71f7960809c38f2526c1cd` is 774 commits behind fetched `origin/26.2` (`f25a43cbecf89787409c83bfb96c6b465353155e`). The pin is a deliberate release branch, not an auto-following dependency. Its local macOS port modifications remain present. The current pinned tree rebuilt RADV successfully; advancing it would require port rebasing and runtime revalidation, so no unreviewed update was applied.

This refresh is a fetch-and-compare audit only. It did not mutate submodule checkouts or overwrite the dirty NVIDIA reference tree.

## Refresh check (2026-10-22, later session)

A new read-only fetch found the reference upstream advanced to
`9e0f55aef24b1b6e34802f858d15a2395f3c6ba7` (127 commits ahead of local
`b737ded`). Relevant changed paths are NVIDIA `nvrm-accel.cpp` and
`nvaccel_stubs.h` plus removed NVIDIA-only files; the acceleration delta is
surface synchronization, headless/display handling, performance statistics,
and temperature publication. It does not add AMD VM/task lifetime, AMD
scheduler submission, or client IOAccel decode contracts. `IOAccelTask.h`,
`IOAccelMemoryMap.h`, and `IOGraphicsAccelerator2.h` are byte-identical at
local HEAD and fetched upstream. The dirty local policy edits and untracked
`gpu-port/*` are preserved. No merge/cherry-pick/fast-forward was done.

The fetched Mesa `origin/26.2` and pinned `deps/mesa` remain 774 commits apart;
`deps/libdrm` still equals its fetched upstream `origin/main`. The pinned Mesa
port was rebuilt successfully in this session, so no dependency advance was
justified by this audit; a refresh would require a reviewed rebase and runtime
qualification rather than an unreviewed version bump.

## Validation

- `git fetch origin` in the research tree: rc=0.
- Diff check on this report (`git diff --no-index --check -- /dev/null docs/reports/dependency-audit.md`): no whitespace
  errors reported; 0 trailing-whitespace lines of 103. The command exits 1 because the file differs from /dev/null, which is expected for `--no-index`.
- Research tree after audit: HEAD `b737ded`, origin/main `47f818b`, 4 porcelain entries (unchanged: 2 modified, 2 untracked).
