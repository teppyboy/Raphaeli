/*
 * Shared between the RaphaeliFB IOFramebuffer (nmx_fb.cpp) and nothing else: the kernel-internal scanout
 * interface from docs/display-accel-contract.md. The scanout lane implements the exact signatures in
 * bsdcompat/src/nmx_scanout.c; a mismatch here is an integration failure.
 */
#ifndef NMXKPI_NMX_FB_INTERNAL_H
#define NMXKPI_NMX_FB_INTERNAL_H

#include <stddef.h>
#include <stdint.h>
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

struct NMXFbMode {
    uint32_t width, height;
    uint32_t pitch;             /* bytes */
    uint64_t pclk_hz;
    uint32_t hblank, vblank;
    uint32_t hsync_off, hsync_pw, vsync_off, vsync_pw;
};

static inline uint32_t nmx_fb_pitch(uint32_t width)
{
    return (width * NMX_FB_BPP / 8 + NMX_FB_PITCH_ALIGN - 1u) & ~(NMX_FB_PITCH_ALIGN - 1u);
}

/*
 * The detailed-timing block of one 128-byte EDID (d = first byte of the block) as an NMXFbMode, or false when
 * the block is malformed or its timing is not sane enough to drive a panel. Pure bytes in, mode out, so the
 * self-check in nmx_fb_edid_test.cpp runs on the host against real EDID layouts.
 */
static inline bool nmx_fb_edid_timing(const uint8_t *d, NMXFbMode *m)
{
    if (!d || !m)
        return false;
    uint8_t sum = 0;
    for (int b = 0; b < 128; b++)
        sum += d[b];
    if (sum != 0)
        return false;
    uint32_t pclk = (uint32_t)(d[54] | (d[55] << 8)) * 10000;   /* EDID pixel clock is in 10 kHz units */
    uint32_t hact = (uint32_t)(d[56] | ((d[58] >> 4) << 8)), hblk = (uint32_t)(d[57] | ((d[58] & 0xF) << 8));
    uint32_t vact = (uint32_t)(d[59] | ((d[61] >> 4) << 8)), vblk = (uint32_t)(d[60] | ((d[61] & 0xF) << 8));
    uint32_t hso = (uint32_t)(d[62] | ((d[65] >> 6) << 8)), hsw = (uint32_t)(d[63] | (((d[65] >> 4) & 3) << 8));
    uint32_t vso = (uint32_t)((d[64] >> 4) | (((d[65] >> 2) & 3) << 8)), vsw = (uint32_t)((d[64] & 0xF) | ((d[65] & 3) << 8));
    if (pclk < 20000000 || pclk > 400000000 || hact < 640 || vact < 400 || hblk == 0 || vblk == 0
        || hact + hblk > 16384 || vact + vblk > 16384)
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

#endif /* NMXKPI_NMX_FB_INTERNAL_H */
