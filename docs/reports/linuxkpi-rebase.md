# LinuxKPI rebase: 169e254b844 → f4fe4c3d17f

## Result
- kpi/freebsd-src moved to f4fe4c3d17f (clean gitlink, `ignore = dirty` already set).
- `patches/freebsd-src-linuxkpi.patch` deleted; patch step removed from `scripts/kpi-init.sh`.
- Build: 900/900, runtime: 81/81, link `out-disp` OK, `kmutil inspect -V tb -p out-disp/Raphaeli.kext` rc=0.
- Commit: `416c9b1 linuxkpi: rebase port onto freebsd-src f4fe4c3d17f`.

## Per-family decisions (upstream vs ours)

| Family | Old shim (deleted) | New upstream | Decision |
|---|---|---|---|
| `x86_cpu_id`/`x86_stepping` (processor.h) | patch added fields | upstream has both | upstream supersedes; patch dropped |
| `sd` in `struct kobject` (kobject.h) | patch | upstream has `void *sd` | upstream supersedes |
| `dma_length`/`sg_dma_len` (scatterlist.h) | patch | upstream has `unsigned int dma_length` | upstream supersedes |
| `__ATTR_RW_MODE` (sysfs.h) | patch | upstream defines it | upstream supersedes |
| `dma_unmap_page_attrs` (nmxkpi_post.h macro → dropped attrs) | ours | upstream inline passing attrs to `lkpi_dma_unmap` | **keep upstream** — our `lkpi_dma_unmap` fork already honors `DMA_ATTR_SKIP_CPU_SYNC` |
| `usleep_range_state`/`usleep_range` (nmxkpi_post.h macro) | ours (dropped state, interruptible sleep) | upstream inline: `pause_sbt` + `KASSERT(state == TASK_UNINTERRUPTIBLE)` | **keep upstream** — our Compat layer provides `pause_sbt`/`ustosbt` (`sys/proc.h`, `sys/time.h`); KASSERT documents the real constraint instead of silently dropping it |
| `pm_resume_via_firmware` (nmxkpi_post.h `static inline int`) | ours | upstream `static inline bool` in `linux/suspend.h` | **keep upstream** (same semantics: always false) |
| `acpi_video_get_edid` (nmxkpi_post.h inline) | ours | upstream `static inline` in `acpi/video.h`, `-ENODEV` | **keep upstream** (same semantics) |
| `strscpy` 2/3-arg pick macro (nmxkpi_post.h) | ours (routed 3-arg to a function that no longer exists) | upstream macro via `sized_strscpy` + `COUNT_ARGS` (our `args.h` override extends COUNT_ARGS to 15) | **keep upstream**, delete ours |
| `pmap_change_attr` / `PHYS_TO_DMAP` | ours: `vm_offset_t` va / `vm_offset_t` result | upstream calls with `void *va`, assigns `PHYS_TO_DMAP` to `void *` | **change ours to FreeBSD 15 signatures**: `pmap_change_attr(void *va, ...)` (stub, `nmx_page.c`), `PHYS_TO_DMAP` yields `void *` (`vm/vm_page.h`); `PHYS_TO_DMAP_ADDR` stays integer |
| `pci_lock`/`pci_drivers`/`pci_devices` | upstream globals, externs in `linux/pci.h` | upstream made them `lkpi_`-prefixed statics in `linux_pci.c` | **keep ours** — shared registry lives in our `linux_compat.c` fork; added externs to our `linux_pci.c` fork |
| `timer_list` callback | old `function(timer->data)` | upstream removed `data`; `function(timer)` | **keep upstream shape** — one-line fix in `linux_compat.c` wrapper |

## Remaining deltas
- Our `linux_compat.c` / `linux_pci.c` forks still diverge from upstream (xnu adaptations); only compile-relevant conflicts resolved.
- `ACPI_COMPANION(dev) NULL` and `ACPI_VIDEO_DISPLAY_LCD 0` kept in `nmxkpi_post.h` (upstream does not provide xnu equivalents; no conflicts).

## Risks
- `usleep_range_state` now enforces `TASK_UNINTERRUPTIBLE` via KASSERT; any caller passing another state would trip at runtime (debug kernels only).
- `PHYS_TO_DMAP` type change (integer → pointer) is global; grep shows no other consumers besides upstream LinuxKPI headers, but future callers must use `PHYS_TO_DMAP_ADDR` for integer contexts.
- Upstream `dma_unmap_page_attrs` now really forwards attrs; behavior change vs old shim that silently dropped them (correct: SKIP_CPU_SYNC now honored).
