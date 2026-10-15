/*
 * Host-side self-check for nmx_fb_edid_timing (nmx_fb_internal.h): real EDID byte layouts, assert-based.
 * Not part of the kext (nothing links it; lives outside Kernel/ so the kernel-flag glob never sees it); built and run by hand: clang++ -std=c++17 -I Raphaeli/Kernel scripts/tests/nmx_fb_edid_test.cpp && ./a.out
 */
#include <assert.h>
#include <string.h>
#include <stdio.h>
#include "nmx_fb_internal.h"

static void dtd(uint8_t *d, int j, uint32_t pclk10k, uint32_t hact, uint32_t hblk,
                uint32_t vact, uint32_t vblk, uint32_t hso, uint32_t hsw,
                uint32_t vso, uint32_t vsw)
{
    uint8_t *t = d + 54 + 18 * j;
    t[0] = pclk10k & 0xFF;
    t[1] = pclk10k >> 8;
    t[2] = hact & 0xFF;
    t[3] = hblk & 0xFF;
    t[4] = ((hact >> 8) << 4) | (hblk >> 8);
    t[5] = vact & 0xFF;
    t[6] = vblk & 0xFF;
    t[7] = ((vact >> 8) << 4) | (vblk >> 8);
    t[8] = hso & 0xFF;
    t[9] = hsw & 0xFF;
    t[10] = ((vso & 0xF) << 4) | (vsw & 0xF);
    t[11] = ((hso >> 8) << 6) | ((hsw >> 8) << 4) | ((vso >> 8) << 2) | (vsw >> 8);
}

static void edid(uint8_t *d, uint32_t pclk10k, uint32_t hact, uint32_t hblk,
                 uint32_t vact, uint32_t vblk, uint32_t hso, uint32_t hsw,
                 uint32_t vso, uint32_t vsw)
{
    memset(d, 0, 128);
    memcpy(d, "\x00\xff\xff\xff\xff\xff\xff\x00", 8);
    dtd(d, 0, pclk10k, hact, hblk, vact, vblk, hso, hsw, vso, vsw);
    uint8_t sum = 0;
    for (int b = 0; b < 127; b++)
        sum += d[b];
    d[127] = (uint8_t)(256 - sum);
}

static void checksum(uint8_t *d)
{
    uint8_t sum = 0;
    for (int b = 0; b < 127; b++)
        sum += d[b];
    d[127] = (uint8_t)(256 - sum);
}

int main()
{
    NMXFbMode m = {};

    /* standard 1920x1080@60 CVT-R-ish timing, as many panels embed it */
    uint8_t d[128];
    edid(d, 14850, 1920, 280, 1080, 45, 88, 44, 4, 5);
    assert(nmx_fb_edid_timing(d, &m));
    assert(m.width == 1920 && m.height == 1080);
    assert(m.pitch == 7680);
    assert(m.pclk_hz == 148500000ull);
    assert(m.hblank == 280 && m.vblank == 45);
    assert(m.hsync_off == 88 && m.hsync_pw == 44);
    assert(m.vsync_off == 4 && m.vsync_pw == 5);

    /* the 2-bit high fields of byte 65 must survive: 2560x1440 with wide sync offsets */
    edid(d, 24150, 2560, 160, 1440, 95, 128, 64, 3, 8);
    assert(nmx_fb_edid_timing(d, &m));
    assert(m.width == 2560 && m.height == 1440);
    assert(m.hsync_off == 128 && m.hsync_pw == 64 && m.vsync_off == 3 && m.vsync_pw == 8);

    /* bad checksum: rejected */
    edid(d, 14850, 1920, 280, 1080, 45, 88, 44, 4, 5);
    d[127] ^= 0xFF;
    assert(!nmx_fb_edid_timing(d, &m));

    /* insane pixel clock and tiny active area: rejected */
    edid(d, 100, 1920, 280, 1080, 45, 88, 44, 4, 5);
    assert(!nmx_fb_edid_timing(d, &m));
    edid(d, 14850, 320, 280, 200, 45, 88, 44, 4, 5);
    assert(!nmx_fb_edid_timing(d, &m));

    /* null arguments: rejected */
    assert(!nmx_fb_edid_timing(nullptr, &m));
    assert(!nmx_fb_edid_timing(d, nullptr));

    /* pitch alignment: 1366-wide panel rows still align to 256 bytes */
    edid(d, 8550, 1366, 434, 768, 30, 64, 56, 3, 4);
    assert(nmx_fb_edid_timing(d, &m));
    assert(m.width == 1366 && m.pitch == 5632 && m.pitch % 256 == 0);

    /*
     * Full mode list of one EDID block: three sane detailed timings (1080p preferred, then 720p, then a
     * 640x480 dup of the established bitmap), established bits 640x480@60 + 800x600@60, and one standard
     * timing (1280x720@60, 16:9). Everything dedups down to 4 modes, preferred first.
     */
    memset(d, 0, 128);
    memcpy(d, "\x00\xff\xff\xff\xff\xff\xff\x00", 8);
    dtd(d, 0, 14850, 1920, 280, 1080, 45, 88, 44, 4, 5);
    dtd(d, 1, 7425, 1280, 370, 720, 30, 220, 40, 5, 5);
    dtd(d, 2, 2518, 640, 160, 480, 45, 16, 96, 10, 2);
    d[0x18] |= 0x02;                              /* preferred timing is the first detailed descriptor */
    d[0x23] = 0x21;                               /* established: 640x480@60 (bit 5), 800x600@60 (bit 7) */
    d[0x26] = 0xA0;                               /* standard: 1280 wide (0xA0 * 8) */
    d[0x27] = 0xC0 | 0x00;                        /* 16:9, 60 Hz */
    checksum(d);
    NMXFbMode modes[NMX_FB_MAX_MODES] = {};
    uint32_t n = nmx_fb_edid_modes(d, modes, NMX_FB_MAX_MODES);
    assert(n == 4);
    assert(modes[0].width == 1920 && modes[0].height == 1080 && modes[0].preferred);
    assert(modes[0].pclk_hz == 148500000ull && modes[0].pitch == 7680);
    assert(modes[0].hsync_off == 88 && modes[0].hsync_pw == 44);
    assert(modes[0].vsync_off == 4 && modes[0].vsync_pw == 5);
    assert(modes[1].width == 1280 && modes[1].height == 720);
    assert(modes[2].width == 640 && modes[2].height == 480);   /* established dup folded into the DTD slot */
    assert(modes[3].width == 800 && modes[3].height == 600);
    /* every GTF-derived mode hits its requested refresh within 1 Hz and passes the sanity ranges */
    for (uint32_t i = 0; i < n; i++) {
        uint64_t r = (nmx_fb_refresh16(&modes[i]) + 0x8000) / 65536;
        assert(r >= 59 && r <= 61);
        assert(modes[i].pclk_hz >= 20000000 && modes[i].pclk_hz <= 400000000);
        assert(modes[i].hblank > 0 && modes[i].vblank > 0);
    }

    /* no preferred bit: the detailed timings stay in EDID order (1080p first anyway); prefer second flag off */
    d[0x18] &= ~(uint8_t)0x02;
    dtd(d, 0, 7425, 1280, 370, 720, 30, 220, 40, 5, 5);
    dtd(d, 1, 14850, 1920, 280, 1080, 45, 88, 44, 4, 5);
    memset(d + 54 + 36, 0, 18);                   /* drop the third detailed timing of the previous block */
    d[0x23] = 0;
    d[0x26] = d[0x27] = 0x01;                     /* unused standard slots */
    checksum(d);
    n = nmx_fb_edid_modes(d, modes, NMX_FB_MAX_MODES);
    assert(n == 2);
    assert(modes[0].width == 1280 && modes[1].width == 1920);
    assert(!modes[0].preferred && !modes[1].preferred);

    /* truncation at max */
    d[0x18] |= 0x02;
    d[0x23] = 0xFF, d[0x24] = 0xFF, d[0x25] = 0x80;   /* every established bit */
    checksum(d);
    n = nmx_fb_edid_modes(d, modes, 3);
    assert(n == 3 && modes[0].width == 1280);     /* preferred detailed first even when truncated */

    /* bad checksum: no modes */
    d[127] ^= 0xFF;
    assert(nmx_fb_edid_modes(d, modes, NMX_FB_MAX_MODES) == 0);
    /* null arguments: no modes */
    assert(nmx_fb_edid_modes(nullptr, modes, NMX_FB_MAX_MODES) == 0);
    assert(nmx_fb_edid_modes(d, nullptr, NMX_FB_MAX_MODES) == 0);
    assert(nmx_fb_edid_modes(d, modes, 0) == 0);

    /* GTF standalone: a standard-timing-shaped 1024x768@70 produces sane blanking around the request */
    assert(nmx_fb_gtf_timing(1024, 768, 70, &m));
    assert(m.width == 1024 && m.height == 768);
    assert(m.hblank % 16 == 0);
    assert((nmx_fb_refresh16(&m) + 0x8000) / 65536 == 70);
    assert(!nmx_fb_gtf_timing(320, 200, 60, &m));
    assert(!nmx_fb_gtf_timing(640, 480, 30, &m));
    assert(!nmx_fb_gtf_timing(640, 480, 60, nullptr));

    printf("nmx_fb_edid_test: all checks passed\n");
    return 0;
}
