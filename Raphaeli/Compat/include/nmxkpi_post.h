/* Included after LinuxKPI's compiler headers in every translation unit of the port. */
#ifndef NMXKPI_POST_H
#define NMXKPI_POST_H
/* Xcode's clang rejects __typeof__ on a flexible array annotated with counted_by; the annotation is a bounds-check
 * hint only, so it is dropped here. */
#undef __counted_by
#define __counted_by(member)
#endif

/* xnu's stdbool makes 'bool' a macro (FreeBSD a typedef); a parameter type passed through one more macro layer then
 * reaches LINUXKPI_PARAM_##type as _Bool (i915_param_named(x, bool, ...)) */
#define LINUXKPI_PARAM__Bool LINUXKPI_PARAM_bool

/* LinuxKPI never declares struct vfsmount; a first use inside a function prototype would declare a
 * prototype-scoped tag and clang then rejects identical signatures as "conflicting types". */
struct vfsmount;
/* GEM gemfs mounts do not exist on xnu: every shmem object uses the same backing store. */
#define shmem_file_setup_with_mnt(mnt, name, size, flags) linux_shmem_file_setup(name, size, flags)

/* Linux 6.14 renamed kthread_create_worker to kthread_run_worker; LinuxKPI only has the old name. */
#define kthread_run_worker(flags, fmt, ...) kthread_create_worker(flags, fmt, ##__VA_ARGS__)

/* usleep_range_state: the state argument (TASK_UNINTERRUPTIBLE etc.) is dropped — LinuxKPI
 * has no way to pick the sleep state, usleep_range already sleeps interruptibly. */
#define usleep_range_state(min, max, state) usleep_range(min, max)

/* DMA attr flags are dropped: LinuxKPI's dma_unmap_page ignores them. */
#define dma_unmap_page_attrs(dev, addr, size, dir, attrs) dma_unmap_page(dev, addr, size, dir)

/* ACPI S4 resume never goes through firmware on this port; callers only test "are we resuming
 * from hibernate", which is always false under xnu kexts. */
static inline int pm_resume_via_firmware(void) { return (0); }

/* xnu has no ACPI video extension: the companion device never exists, EDID probes
 * fall back to the connector's own DDC. */
#define ACPI_COMPANION(dev) NULL
#define ACPI_VIDEO_DISPLAY_LCD 0
#include <sys/errno.h>
static inline int acpi_video_get_edid(void *acpidev, int display_type,
    int device_id, void **edid) { return (-ENODEV); }

/* Linux's strscpy takes an explicit length; a few drm-kmod callers use the 2-arg
 * FreeBSD form, which copies into a fixed-size array (fb->comm). Pulled in here so
 * the macro below cannot mangle string.h's own strscpy definition. */
#include <linux/string.h>
#define nmx_strscpy_2(dst, src) strscpy((dst), (src), sizeof(dst))
#define nmx_strscpy_3(dst, src, len) strscpy((dst), (src), (len))
#define nmx_strscpy_pick(_1, _2, _3, name, ...) name
#define strscpy(...) nmx_strscpy_pick(__VA_ARGS__, nmx_strscpy_3, nmx_strscpy_2)(__VA_ARGS__)
