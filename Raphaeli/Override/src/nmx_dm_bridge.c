/*
 * The display-engine bridge, amdgpu side: RaphaeliFB's mode changes run on the port's real DC display
 * core instead of only bookkeeping (review P1-2: setDisplayMode was nominal).
 *
 * One set-mode is the kernel-internal shape of amdgpu_dm's own modeset, without DRM:
 *   dc_create_stream_for_sink + the timing from NMXFbMode (the NMXFbMode-shaped part of dm's
 *   fill_stream_properties_from_drm_display_mode), then dc_commit_streams (where
 *   amdgpu_dm_commit_streams ends), then dc_update_planes_and_stream with one linear XRGB8888 plane
 *   whose address is the scanout buffer's physical run (where amdgpu_dm_commit_planes ends). The DC
 *   core owns the link: the eDP sink was detected at driver init, and the commit path trains the link
 *   and enables the stream like any modeset. The previously committed stream is detached first, the
 *   same way amdgpu_dm_commit_zero_streams removes streams.
 *
 * Unknown input, no live DC core, no sink on the connector: refused with an errno, and the framebuffer
 * keeps the firmware timing rather than lying about success. Nothing here panics.
 *
 * v1: one GPU — the device the kext registered last (nmx_dm_bridge_init's iopci) is served; one
 * connector per framebuffer (index 0 = the first connected link, eDP first).
 */
#include <linux/kernel.h>
#include <linux/pci.h>
#include <linux/mutex.h>
#include <string.h>

#include <drm/drm_device.h>
#include <drm/drm_drv.h>

#include <sys/param.h>
#include <sys/systm.h>
#include <sys/malloc.h>
#include <sys/bus.h>
#include <machine/atomic.h>

#include "amdgpu.h"
#include "dc.h"
#include "dc_stream.h"
#include "dc_plane.h"
#include "dc_state.h"

#include "../../Kernel/nmx_dm_bridge.h"
#include "../../Kernel/nmx_fb_internal.h"   /* NMXFbMode + nmx_fb_mode_sane (the boundary header forward-declares only) */

enum dm_refusal_stage {
    DM_REFUSE_MODE_INPUT,
    DM_REFUSE_MODE_DEVICE,
    DM_REFUSE_MODE_CONNECTOR,
    DM_REFUSE_MODE_DETACH,
    DM_REFUSE_MODE_STREAM_CREATE,
    DM_REFUSE_MODE_VALIDATE,
    DM_REFUSE_MODE_COMMIT,
    DM_REFUSE_FLIP_PLANE_CREATE,
    DM_REFUSE_FLIP_UPDATE,
    DM_REFUSE_COUNT
};

static volatile unsigned int dm_refusals[DM_REFUSE_COUNT];

static const char *dm_refusal_stage_name(enum dm_refusal_stage stage)
{
    static const char *const names[DM_REFUSE_COUNT] = {
        "mode-input", "mode-device", "mode-connector", "mode-detach", "mode-stream-create",
        "mode-validate", "mode-commit", "flip-plane-create", "flip-update"
    };
    return stage < DM_REFUSE_COUNT ? names[stage] : "unknown";
}

static int dm_refused(enum dm_refusal_stage stage, int err)
{
    unsigned int count = atomic_fetchadd_int(&dm_refusals[stage], 1) + 1;
    device_printf(NULL, "Raphaeli dm bridge: refusal stage=%s count=%u errno=%d\n",
                  dm_refusal_stage_name(stage), count, err);
    return err;
}

/* the amdgpu_device of the attached driver on 'iopci', or NULL (same walk as nmx_accel_bridge.c) */
static struct amdgpu_device *adev_of(void *iopci)
{
    device_t dev = nmx_device_for_pci(iopci);
    device_t *kids = NULL;
    int n = 0;
    struct amdgpu_device *adev = NULL;
    if (dev == NULL || device_get_children(dev, &kids, &n) != 0)
        return NULL;
    for (int i = 0; i < n && adev == NULL; i++) {
        if (!device_is_attached(kids[i]))
            continue;
        struct pci_dev *pdev = device_get_softc(kids[i]);
        struct drm_device *drm = pdev != NULL ? pci_get_drvdata(pdev) : NULL;
        if (drm != NULL && drm->driver != NULL && drm->driver->name != NULL &&
            strcmp(drm->driver->name, "amdgpu") == 0)
            adev = drm_to_adev(drm);
    }
    free(kids, M_TEMP);
    return adev;
}

/* the live DC core behind 'iopci', or NULL */
static struct dc *dc_of(void *iopci)
{
    struct amdgpu_device *adev = adev_of(iopci);
    if (adev == NULL || !adev->accel_working || adev->in_suspend || adev->shutdown)
        return NULL;
    if (adev->dm.dc == NULL || adev->dm.dc->current_state == NULL)
        return NULL;
    return adev->dm.dc;
}

/* the 'index'-th connected link (eDP first, the same ordering nmx_dm_bridge_init reports) */
static struct dc_link *link_for(struct dc *dc, uint32_t index)
{
    uint32_t n = 0;
    for (int pass = 0; pass < 2; pass++)
        for (uint8_t i = 0; i < dc->link_count; i++) {
            struct dc_link *link = dc->links[i];
            if (link == NULL || link->local_sink == NULL)
                continue;
            bool edp = link->local_sink->sink_signal == SIGNAL_TYPE_EDP;
            if ((pass == 0) != edp)
                continue;
            if (n == index)
                return link;
            n++;
        }
    return NULL;
}

/* NMXFbMode -> dc_crtc_timing (the NMXFbMode-shaped part of dm's fill_stream_properties_from_drm_display_mode) */
static void fill_timing(struct dc_crtc_timing *t, const NMXFbMode *m)
{
    memset(t, 0, sizeof(*t));
    t->h_addressable = m->width;
    t->h_total = m->width + m->hblank;
    t->h_front_porch = m->hsync_off;
    t->h_sync_width = m->hsync_pw;
    t->v_addressable = m->height;
    t->v_total = m->height + m->vblank;
    t->v_front_porch = m->vsync_off;
    t->v_sync_width = m->vsync_pw;
    t->pix_clk_100hz = m->pclk_hz / 100;
    t->pixel_encoding = PIXEL_ENCODING_RGB;
    t->display_color_depth = COLOR_DEPTH_888;
    t->timing_3d_format = TIMING_3D_FORMAT_NONE;
    t->scan_type = SCANNING_TYPE_NODATA;
    t->aspect_ratio = ASPECT_RATIO_NO_DATA;
    t->flags.INTERLACE = m->interlace;
    t->flags.HSYNC_POSITIVE_POLARITY = m->positive_hsync;
    t->flags.VSYNC_POSITIVE_POLARITY = m->positive_vsync;
}

/* commit a state that no longer contains 'stream' (amdgpu_dm_commit_zero_streams, for one stream;
   v1 drives one head, so the state left after the detach has no streams) */
#define NMX_DM_STATUS_POLL_US 1000
#define NMX_DM_STATUS_POLL_COUNT 50

/* Read back the committed plane until DC exposes the address requested by the update. */
static bool scanout_status_matches(struct dc_stream_state *stream, uint64_t expected, uint64_t *actual)
{
    for (unsigned int attempt = 0; attempt < NMX_DM_STATUS_POLL_COUNT; attempt++) {
        struct dc_stream_status *status = dc_stream_get_status(stream);
        if (status != NULL && status->plane_count > 0 && status->plane_states[0] != NULL) {
            const struct dc_plane_address *a = &status->plane_states[0]->address;
            uint64_t address = (uint64_t)a->grph.addr.low_part | ((uint64_t)a->grph.addr.high_part << 32);
            if (actual != NULL)
                *actual = address;
            if (address == expected)
                return true;
        }
        if (attempt + 1 < NMX_DM_STATUS_POLL_COUNT)
            DELAY(NMX_DM_STATUS_POLL_US);
    }
    return false;
}

static int detach_stream(struct amdgpu_device *adev, struct dc_stream_state *stream)
{
    struct dc *dc = adev->dm.dc;
    struct dc_state *context = dc_state_create_current_copy(dc);
    if (context == NULL)
        return dm_refused(DM_REFUSE_MODE_DETACH, -ENOMEM);
    enum dc_status res = DC_OK;
    if (!dc_state_rem_all_planes_for_stream(dc, stream, context))
        res = DC_FAIL_DETACH_SURFACES;
    else
        res = dc_state_remove_stream(dc, context, stream);
    if (res == DC_OK) {
        struct dc_commit_streams_params params = {};
        params.power_source = DC_POWER_SOURCE_AC;
        res = dc_commit_streams(dc, &params);   /* 0 streams: the detached stream leaves the pipe */
    }
    dc_state_release(context);
    return res == DC_OK ? 0 : dm_refused(DM_REFUSE_MODE_DETACH, -EIO);
}

int nmx_dm_bridge_init(void *iopci)
{
    struct dc *dc = dc_of(iopci);
    if (dc == NULL)
        return dm_refused(DM_REFUSE_MODE_DEVICE, -ENODEV);
    uint32_t count = 0;
    for (int pass = 0; pass < 2; pass++)
        for (uint8_t i = 0; i < dc->link_count; i++) {
            struct dc_link *link = dc->links[i];
            if (link == NULL || link->local_sink == NULL)
                continue;
            if ((pass == 0) != (link->local_sink->sink_signal == SIGNAL_TYPE_EDP))
                continue;
            device_printf(NULL, "Raphaeli dm bridge: connector %u: link %u signal %d sink \"%s\"\n", count,
                          link->link_index, link->local_sink->sink_signal,
                          link->local_sink->edid_caps.display_name);
            count++;
        }
    if (count == 0) {
        device_printf(NULL, "Raphaeli dm bridge: the DC core is up but no connector has a sink\n");
        return dm_refused(DM_REFUSE_MODE_CONNECTOR, -ENODEV);
    }
    return (int)count;
}

int nmx_dm_bridge_set_mode(void *iopci, uint32_t index, const NMXFbMode *m, uint64_t scanout_phys,
                           uint64_t *scanout_out)
{
    if (scanout_out)
        *scanout_out = 0;
    if (m == NULL || scanout_phys == 0 ||
        !nmx_fb_mode_sane(m->pclk_hz, m->width, m->height, m->hblank, m->vblank))
        return dm_refused(DM_REFUSE_MODE_INPUT, -EINVAL);

    struct amdgpu_device *adev = adev_of(iopci);
    struct dc *dc = dc_of(iopci);
    if (adev == NULL || dc == NULL)
        return dm_refused(DM_REFUSE_MODE_DEVICE, -ENODEV);
    struct dc_link *link = link_for(dc, index);
    if (link == NULL || link->local_sink == NULL)
        return dm_refused(DM_REFUSE_MODE_CONNECTOR, -ENODEV);
    struct dc_sink *sink = link->local_sink;

    /* the whole sequence under dm's dc_lock, like every dm commit */
    mutex_lock(&adev->dm.dc_lock);

    /* the previous stream must leave the pipe before the new one validates (one CRTC, one pipe) */
    if (dc_get_current_stream_count(dc) > 0) {
        int r = detach_stream(adev, dc_get_stream_at_index(dc, 0));
        if (r) {
            mutex_unlock(&adev->dm.dc_lock);
            return r;
        }
    }

    int err;
    struct dc_stream_state *stream = dc_create_stream_for_sink(sink);
    if (stream == NULL) {
        err = -ENOMEM;
        goto refuse_stream_create;
    }
    fill_timing(&stream->timing, m);
    stream->out_transfer_func.type = TF_TYPE_PREDEFINED;
    stream->out_transfer_func.tf = TRANSFER_FUNCTION_SRGB;
    stream->output_color_space = COLOR_SPACE_SRGB;
    stream->src.width = m->width;
    stream->src.height = m->height;
    stream->dst = stream->src;

    enum dc_status res = dc_validate_stream(dc, stream);
    if (res != DC_OK) {
        device_printf(NULL, "Raphaeli dm bridge: %ux%u@%llukHz on link %u refused: dc status %d\n", m->width,
                      m->height, (unsigned long long)(m->pclk_hz / 1000), link->link_index, res);
        err = -EINVAL;
        goto refuse_validate;
    }

    struct dc_commit_streams_params params = {};
    params.streams = &stream;
    params.stream_count = 1;
    params.power_source = DC_POWER_SOURCE_AC;
    res = dc_commit_streams(dc, &params);
    if (res != DC_OK) {
        device_printf(NULL, "Raphaeli dm bridge: the %ux%u commit failed: dc status %d\n", m->width, m->height, res);
        err = -EIO;
        goto refuse_commit;
    }

    /* one linear XRGB8888 plane over the scanout buffer (the plane dm commits on every modeset) */
    struct dc_plane_info pinfo = {};
    pinfo.format = SURFACE_PIXEL_FORMAT_GRPH_ARGB8888;
    pinfo.color_space = COLOR_SPACE_SRGB;
    pinfo.visible = true;
    pinfo.rotation = ROTATION_ANGLE_0;
    pinfo.stereo_format = PLANE_STEREO_FORMAT_NONE;
    pinfo.pre_multiplied_alpha = true;
    pinfo.global_alpha_value = 0xff;
    pinfo.layer_index = 0;
    pinfo.plane_size.surface_size.width = m->width;
    pinfo.plane_size.surface_size.height = m->height;
    pinfo.plane_size.surface_pitch = m->pitch / 4;
    pinfo.tiling_info.gfxversion = DcGfxVersion9;
    pinfo.tiling_info.gfx9.swizzle = DC_SW_LINEAR;
    pinfo.tiling_info.gfx9.num_pipes = adev->gfx.config.gb_addr_config_fields.num_pipes;
    pinfo.tiling_info.gfx9.num_banks = adev->gfx.config.gb_addr_config_fields.num_banks;
    pinfo.tiling_info.gfx9.pipe_interleave = adev->gfx.config.gb_addr_config_fields.pipe_interleave_size;
    pinfo.tiling_info.gfx9.num_shader_engines = adev->gfx.config.gb_addr_config_fields.num_se;
    pinfo.tiling_info.gfx9.max_compressed_frags = adev->gfx.config.gb_addr_config_fields.max_compress_frags;
    pinfo.tiling_info.gfx9.num_rb_per_se = adev->gfx.config.gb_addr_config_fields.num_rb_per_se;
    pinfo.tiling_info.gfx9.shaderEnable = 1;
    pinfo.tiling_info.gfx9.num_pkrs = adev->gfx.config.gb_addr_config_fields.num_pkrs;

    struct dc_plane_address addr = {};
    addr.type = PLN_ADDR_TYPE_GRAPHICS;
    addr.grph.addr.low_part = lower_32_bits(scanout_phys);
    addr.grph.addr.high_part = upper_32_bits(scanout_phys);

    struct dc_scaling_info sinfo = {};
    sinfo.src_rect.width = m->width;
    sinfo.src_rect.height = m->height;
    sinfo.dst_rect = sinfo.src_rect;
    sinfo.clip_rect = sinfo.dst_rect;

    struct dc_flip_addrs flip = {};
    flip.address = addr;

    struct dc_plane_state *plane = dc_create_plane_state(dc);
    if (plane == NULL) {
        err = -ENOMEM;
        goto refuse_plane_create;
    }

    struct dc_surface_update srf = {};
    srf.surface = plane;
    srf.flip_addr = &flip;
    srf.plane_info = &pinfo;
    srf.scaling_info = &sinfo;
    struct dc_stream_update stream_update = {};
    if (!dc_update_planes_and_stream(dc, &srf, 1, stream, &stream_update)) {
        device_printf(NULL, "Raphaeli dm bridge: the %ux%u plane update failed\n", m->width, m->height);
        dc_plane_state_release(plane);       /* not retained by DC: the update failed */
        err = -EIO;
        goto refuse_flip_update;
    }
    dc_plane_state_release(plane);           /* our reference; the committed state holds its own */

    /* A successful update is not enough: accept the mode only after DC reports our plane address. */
    uint64_t actual = 0;
    if (!scanout_status_matches(stream, scanout_phys, &actual)) {
        printf("Raphaeli dm bridge: %ux%u scanout status refused: expected 0x%llx, got 0x%llx\n",
               m->width, m->height, (unsigned long long)scanout_phys, (unsigned long long)actual);
        err = -ETIMEDOUT;
        goto release_stream;
    }
    if (scanout_out != NULL)
        *scanout_out = actual;
    device_printf(NULL, "Raphaeli dm bridge: %ux%u @ %u.%02u Hz on link %u, scanout 0x%llx\n", m->width, m->height,
                  (uint32_t)(m->pclk_hz / 1000000), (uint32_t)(m->pclk_hz % 1000000) / 10000, link->link_index,
                  (unsigned long long)actual);
    err = 0;
    goto release_stream;

refuse_flip_update:
    err = dm_refused(DM_REFUSE_FLIP_UPDATE, err);
    goto release_stream;
refuse_plane_create:
    err = dm_refused(DM_REFUSE_FLIP_PLANE_CREATE, err);
    goto release_stream;
refuse_commit:
    err = dm_refused(DM_REFUSE_COMMIT, err);
    goto release_stream;
refuse_validate:
    err = dm_refused(DM_REFUSE_VALIDATE, err);
    goto release_stream;
refuse_stream_create:
    err = dm_refused(DM_REFUSE_STREAM_CREATE, err);
    goto out;
release_stream:
    /* the committed state holds its own reference; drop ours */
    dc_stream_release(stream);
out:
    mutex_unlock(&adev->dm.dc_lock);
    return err;
}
