/*
 * Host-side self-check for nmx_fb_edid_timing (nmx_fb_internal.h): real EDID byte layouts, assert-based.
 * Not part of the kext (nothing links it); built and run by hand: clang++ -std=c++17 nmx_fb_edid_test.cpp && ./a.out
 */
#include <assert.h>
#include <string.h>
#include <stdio.h>
#include "nmx_fb_internal.h"

static void edid(uint8_t *d, uint32_t pclk10k, uint32_t hact, uint32_t hblk,
                 uint32_t vact, uint32_t vblk, uint32_t hso, uint32_t hsw,
                 uint32_t vso, uint32_t vsw)
{
    memset(d, 0, 128);
    memcpy(d, "\x00\xff\xff\xff\xff\xff\xff\x00", 8);
    d[54] = pclk10k & 0xFF;
    d[55] = pclk10k >> 8;
    d[56] = hact & 0xFF;
    d[57] = hblk & 0xFF;
    d[58] = ((hact >> 8) << 4) | (hblk >> 8);
    d[59] = vact & 0xFF;
    d[60] = vblk & 0xFF;
    d[61] = ((vact >> 8) << 4) | (vblk >> 8);
    d[62] = hso & 0xFF;
    d[63] = hsw & 0xFF;
    d[64] = ((vso & 0xF) << 4) | (vsw & 0xF);
    d[65] = ((hso >> 8) << 6) | ((hsw >> 8) << 4) | ((vso >> 8) << 2) | (vsw >> 8);
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

    printf("nmx_fb_edid_test: all checks passed\n");
    return 0;
}
