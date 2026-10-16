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

/* xnu has no ACPI video extension: the companion device never exists, EDID probes
 * fall back to the connector's own DDC. */
#define ACPI_COMPANION(dev) NULL
#define ACPI_VIDEO_DISPLAY_LCD 0
