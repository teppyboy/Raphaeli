/*
 * Shared between the RaphaeliFB IOFramebuffer (nmx_fb.cpp) and nothing else: the kernel-internal scanout
 * interface from docs/display-accel-contract.md. The scanout lane implements the exact signatures in
 * bsdcompat/src/nmx_scanout.c; a mismatch here is an integration failure.
 */
#ifndef NMXKPI_NMX_FB_INTERNAL_H
#define NMXKPI_NMX_FB_INTERNAL_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <mach/vm_types.h>
#include <mach/kern_return.h>

#ifdef __cplusplus
extern "C" {
#endif
kern_return_t nmx_scanout_alloc(size_t size, vm_offset_t *phys_addr,
                                vm_offset_t *kern_addr, vm_size_t *mapped);
kern_return_t nmx_scanout_free(vm_offset_t phys_addr, vm_size_t mapped);
#ifdef __cplusplus
}
#endif

/* The one mode of v0. Panel-native when the VBIOS carries a readable EDID (parsed in nmx_fb.cpp), else this
   documented 1920x1080@60 CVT-R-ish placeholder (148.5 MHz, standard 1080p blanking/syncs). */
#define NMX_FB_DEFAULT_WIDTH     1920
#define NMX_FB_DEFAULT_HEIGHT    1080
#define NMX_FB_DEFAULT_PCLK_HZ   148500000ull
#define NMX_FB_DEFAULT_HBLANK    280
#define NMX_FB_DEFAULT_VBLANK    45
#define NMX_FB_DEFAULT_HSYNC_OFF 88
#define NMX_FB_DEFAULT_HSYNC_PW  44
#define NMX_FB_DEFAULT_VSYNC_OFF 4
#define NMX_FB_DEFAULT_VSYNC_PW  5

/* v0 pixel geometry, fixed: XRGB8888, 32 bpp, row aligned to 256 bytes */
#define NMX_FB_BPP 32
#define NMX_FB_PITCH_ALIGN 256

#define NMX_FB_MAX_MODES 32

struct NMXFbMode {
    uint32_t width, height;
    uint32_t pitch;             /* bytes */
    uint64_t pclk_hz;
    uint32_t hblank, vblank;
    uint32_t hsync_off, hsync_pw, vsync_off, vsync_pw;
    bool preferred;             /* EDID preferred-timing bit (byte 0x18 bit 1) on the first detailed timing */
};

static inline uint32_t nmx_fb_pitch(uint32_t width)
{
    return (width * NMX_FB_BPP / 8 + NMX_FB_PITCH_ALIGN - 1u) & ~(NMX_FB_PITCH_ALIGN - 1u);
}

/* The sanity gate every mode must pass to be worth driving a panel (shared by EDID and GTF paths). */
static inline bool nmx_fb_mode_sane(uint64_t pclk, uint32_t hact, uint32_t vact, uint32_t hblk, uint32_t vblk)
{
    return pclk >= 20000000 && pclk <= 400000000 && hact >= 640 && vact >= 400 && hblk != 0 && vblk != 0
        && hact + hblk <= 16384 && vact + vblk <= 16384;
}

/* Refresh of a mode in 16.16 fixed point (pclk / (htotal * vtotal)); 0 when the timing is degenerate. */
static inline uint64_t nmx_fb_refresh16(const NMXFbMode *m)
{
    uint64_t htotal = (uint64_t)m->width + m->hblank, vtotal = (uint64_t)m->height + m->vblank;
    if (m->pclk_hz == 0 || htotal == 0 || vtotal == 0)
        return 0;
    return m->pclk_hz * 65536 / (htotal * vtotal);
}

/*
 * One 18-byte EDID detailed timing descriptor (t) of a 128-byte EDID block (blk, for the checksum) as an
 * NMXFbMode, or false when the descriptor is a monitor descriptor or its timing is not sane enough to drive
 * a panel. Pure bytes in, mode out, so the self-check in nmx_fb_edid_test.cpp runs on the host.
 */
static inline bool nmx_fb_edid_dtd(const uint8_t *blk, const uint8_t *t, NMXFbMode *m)
{
    if (!blk || !t || !m)
        return false;
    m->preferred = false;
    uint8_t sum = 0;
    for (int b = 0; b < 128; b++)
        sum += blk[b];
    if (sum != 0)
        return false;
    if (t[0] == 0 && t[1] == 0)
        return false;                                            /* monitor descriptor, not a timing */
    uint32_t pclk = (uint32_t)(t[0] | (t[1] << 8)) * 10000;      /* EDID pixel clock is in 10 kHz units */
    uint32_t hact = (uint32_t)(t[2] | ((t[4] >> 4) << 8)), hblk = (uint32_t)(t[3] | ((t[4] & 0xF) << 8));
    uint32_t vact = (uint32_t)(t[5] | ((t[7] >> 4) << 8)), vblk = (uint32_t)(t[6] | ((t[7] & 0xF) << 8));
    uint32_t hso = (uint32_t)(t[8] | ((t[11] >> 6) << 8)), hsw = (uint32_t)(t[9] | (((t[11] >> 4) & 3) << 8));
    uint32_t vso = (uint32_t)((t[10] >> 4) | (((t[11] >> 2) & 3) << 8)), vsw = (uint32_t)((t[10] & 0xF) | ((t[11] & 3) << 8));
    if (!nmx_fb_mode_sane(pclk, hact, vact, hblk, vblk))
        return false;
    m->width = hact;
    m->height = vact;
    m->pitch = nmx_fb_pitch(hact);
    m->pclk_hz = pclk;
    m->hblank = hblk;
    m->vblank = vblk;
    m->hsync_off = hso;
    m->hsync_pw = hsw;
    m->vsync_off = vso;
    m->vsync_pw = vsw;
    return true;
}

/*
 * The detailed-timing block of one 128-byte EDID (d = first byte of the block) as an NMXFbMode, or false when
 * the block is malformed or its timing is not sane enough to drive a panel.
 */
static inline bool nmx_fb_edid_timing(const uint8_t *d, NMXFbMode *m)
{
    return nmx_fb_edid_dtd(d, d + 54, m);
}

/*
 * VESA GTF (marginless, non-interlaced): one timing for a standard/established-timing (w x h @ vfreq). The
 * established/standard blocks only carry active area + refresh, so the blanking/sync comes from the GTF
 * formula and the pixel clock is set to hit the requested field rate exactly; same sanity gate as the EDID
 * path. Pure numbers in, mode out, host-testable.
 */
static inline bool nmx_fb_gtf_timing(uint32_t width, uint32_t height, uint32_t vfreq, NMXFbMode *m)
{
    if (!m || width < 640 || height < 400 || vfreq < 50 || vfreq > 200)
        return false;
    const uint32_t CELL = 8, VSYNC = 3;                 /* GTF cell granularity, V sync lines */
    uint32_t hact = (width + CELL / 2) / CELL * CELL;
    uint64_t hperiod = ((1000000ull / vfreq) - 550) / (height + 1);   /* us: min vsync+bp 550us, min porch 1 line */
    if (hperiod == 0)
        return false;
    uint64_t vsync_bp = 550 / hperiod + 1;                            /* back-porch lines (incl. sync) */
    if (vsync_bp < VSYNC)
        vsync_bp = VSYNC;
    uint64_t vtotal = height + vsync_bp + 1;
    uint64_t duty = 3000 - 30 * hperiod;                 /* ideal duty cycle %*100 (C'=30, M'=300, no margins) */
    if (duty < 2000 || duty >= 10000)
        return false;
    uint64_t hblank = hact * duty / (10000 - duty);
    hblank = (hblank + 2 * CELL - 1) / (2 * CELL) * (2 * CELL);
    uint64_t htotal = hact + hblank;
    uint64_t hsync = (hact * 8 / 100 + CELL - 1) / CELL * CELL;       /* GTF: sync = 8% of the line */
    uint64_t pclk = vfreq * vtotal * htotal;                          /* exact requested field rate */
    if (htotal > 16384 || vtotal > 16384 || !nmx_fb_mode_sane(pclk, hact, height, (uint32_t)hblank,
                                                              (uint32_t)(vtotal - height)))
        return false;
    *m = NMXFbMode { hact, height, nmx_fb_pitch(hact), pclk, (uint32_t)hblank, (uint32_t)(vtotal - height),
                     (uint32_t)(hblank / 2), (uint32_t)hsync, (uint32_t)(vsync_bp - VSYNC), VSYNC, false };
    return true;
}

/*
 * All display modes of one 128-byte EDID 1.x block (d = first byte): every sane detailed timing descriptor,
 * plus the established and standard timing blocks when present (blanking/sync from GTF). Deduplicated by
 * active area + refresh (the established/standard blocks usually repeat the detailed timings); the preferred
 * timing (byte 0x18 bit 1 = first detailed descriptor) sorts first. Returns the mode count, 0 when the block
 * is malformed or carries nothing usable; modes are truncated at max.
 */
static inline uint32_t nmx_fb_edid_modes(const uint8_t *d, NMXFbMode *out, uint32_t max)
{
    if (!d || !out || max == 0)
        return 0;
    uint8_t sum = 0;
    for (int b = 0; b < 128; b++)
        sum += d[b];
    if (sum != 0)
        return 0;
    /* the established-timing bitmap (bytes 0x23..0x25), MSB first; the interlaced 1024x768@87 slot is skipped */
    static const uint16_t est[24][3] = {
        { 720, 400, 70 }, { 720, 400, 88 }, { 640, 480, 60 }, { 640, 480, 67 },
        { 640, 480, 72 }, { 640, 480, 75 }, { 800, 600, 56 }, { 800, 600, 60 },
        { 800, 600, 72 }, { 800, 600, 75 }, { 832, 624, 75 }, { 0, 0, 87 },
        { 1024, 768, 60 }, { 1024, 768, 70 }, { 1024, 768, 75 }, { 1280, 1024, 75 },
    };
    NMXFbMode tmp[NMX_FB_MAX_MODES];
    uint32_t n = 0;
    NMXFbMode first = {};
    bool haveFirst = false;
    for (uint32_t j = 0; j < 4 && n < NMX_FB_MAX_MODES; j++) {
        if (nmx_fb_edid_dtd(d, d + 54 + 18 * j, &tmp[n])) {
            if (j == 0) { first = tmp[0]; haveFirst = true; }
            n++;
        }
    }
    for (uint32_t i = 0; i < 24 && n < NMX_FB_MAX_MODES; i++) {
        if (!(d[0x23 + i / 8] & (0x80 >> (i % 8))) || est[i][0] == 0)
            continue;
        if (nmx_fb_gtf_timing(est[i][0], est[i][1], est[i][2], &tmp[n]))
            n++;
    }
    for (uint32_t i = 0; i < 8 && n < NMX_FB_MAX_MODES; i++) {
        uint8_t b1 = d[0x26 + i * 2], b2 = d[0x27 + i * 2];
        if (b1 < 0x20 || b1 == 0x01 || b2 == 0x01)               /* 0x0101 = unused slot */
            continue;
        static const uint32_t num[4] = { 10, 3, 4, 9 }, den[4] = { 16, 4, 5, 16 };  /* 16:10 4:3 5:4 16:9 */
        if (nmx_fb_gtf_timing(b1 * 8, b1 * 8 * num[b2 >> 6] / den[b2 >> 6], (b2 & 0x3F) + 60, &tmp[n]))
            n++;
    }
    uint32_t m = 0;
    for (uint32_t i = 0; i < n; i++) {
        bool dup = false;
        for (uint32_t k = 0; k < m; k++)
            if (tmp[k].width == tmp[i].width && tmp[k].height == tmp[i].height
                && nmx_fb_refresh16(&tmp[k]) + 0x8000 - nmx_fb_refresh16(&tmp[i]) <= 0x10000) {
                dup = true;
                break;
            }
        if (!dup)
            tmp[m++] = tmp[i];
    }
    if (haveFirst && (d[0x18] & 0x02)) {
        for (uint32_t i = 0; i < m && i < max; i++)
            if (memcmp(&tmp[i], &first, sizeof first) == 0) {
                NMXFbMode t = tmp[0];
                tmp[0] = tmp[i];
                tmp[i] = t;
                tmp[0].preferred = true;
                break;
            }
    }
    uint32_t count = m < max ? m : max;
    for (uint32_t i = 0; i < count; i++)
        out[i] = tmp[i];
    return count;
}

#endif /* NMXKPI_NMX_FB_INTERNAL_H */
