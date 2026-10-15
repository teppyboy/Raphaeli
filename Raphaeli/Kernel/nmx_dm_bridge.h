/*
 * The display-engine bridge boundary: the Kernel side (nmx_fb.cpp, IOKit C++) is the consumer, the
 * Override side (Override/src/nmx_dm_bridge.c, which sees the amdgpu driver) is the implementation —
 * the same shape as the accel bridge's boundary (nmx_accel_bridge.c behind nmx_port.h). Plain types
 * only; bridge results are 0 or a negative errno. Every failure path leaves the display core's state
 * untouched and must not panic.
 *
 * C headers in the Kernel directory have no C++ linkage guard; the C++ consumer must include this
 * header inside an extern "C" block (nmx_fb.cpp does), so both languages see the same prototypes.
 */
#ifndef NMX_DM_BRIDGE_H
#define NMX_DM_BRIDGE_H

#include <stdint.h>

struct NMXFbMode;       /* nmx_fb_internal.h, already included by every consumer of this header */

/*
 * Verify the DC display core of the driver attached to 'iopci' is live and enumerate its connected
 * connectors (eDP first). Returns the usable connector count, or a negative errno.
 */
int nmx_dm_bridge_init(void *iopci);

/*
 * Program mode 'm' on connector 'index' and scan out from 'scanout_phys' (one contiguous XRGB8888
 * buffer, 'm->pitch' bytes per row). The physical address the committed plane actually points at is
 * returned in *scanout_out (may be NULL). Returns 0 or a negative errno; on failure the previous
 * timing stays on the panel.
 */
int nmx_dm_bridge_set_mode(void *iopci, uint32_t index, const struct NMXFbMode *m, uint64_t scanout_phys,
                           uint64_t *scanout_out);

#endif /* NMX_DM_BRIDGE_H */
