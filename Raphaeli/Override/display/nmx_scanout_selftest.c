/*
 * Optional self-check of the scanout allocator (nmx_scanout.c), compiled into srcobj/ with the rest of
 * the port but inert unless integration calls nmx_scanout_selftest() — one line in Raphaeli::start()
 * (xnu/nmx_kext.cpp, integration lane) after the port layer starts. With the boot argument
 * raphaeli-scanout-test=1 it allocates one framebuffer-sized buffer, fills it through the WC view,
 * verifies the pattern through the same view, and frees it, logging PASS/FAIL. Without the boot
 * argument it does nothing. Never called on the display path: a failure only logs, it cannot break
 * mode setting.
 */
#include <sys/param.h>
#include <sys/systm.h>
#include <vm/vm.h>
#include <mach/kern_return.h>
#include <pexpert/pexpert.h>

int nmx_scanout_selftest(void);

kern_return_t nmx_scanout_alloc(size_t size, vm_offset_t *phys_addr,
                                vm_offset_t *kern_addr, vm_size_t *mapped);
kern_return_t nmx_scanout_free(vm_offset_t phys_addr, vm_size_t mapped);

int nmx_scanout_selftest(void)
{
    int on = 0;
    if (!PE_parse_boot_argn("raphaeli-scanout-test", &on, sizeof(on)) || on == 0)
        return 0;
    /* one 1080p 32bpp frame, page-rounded by the allocator */
    vm_offset_t pa = 0, kva = 0;
    vm_size_t len = 0;
    kern_return_t kr = nmx_scanout_alloc(1920 * 1080 * 4, &pa, &kva, &len);
    if (kr != KERN_SUCCESS) {
        printf("Raphaeli scanout selftest: alloc failed (%d)\n", kr);
        return -1;
    }
    /* sparse pattern so a WC aliasing bug (wrong page, dropped stores) shows up, not just total loss */
    volatile uint32_t *fb = (volatile uint32_t *)kva;
    for (size_t i = 0; i < len / sizeof(uint32_t); i += 997)
        fb[i] = (uint32_t)(pa + i * sizeof(uint32_t)) | 0xA5A50000u;
    int bad = 0;
    for (size_t i = 0; i < len / sizeof(uint32_t); i += 997) {
        uint32_t want = (uint32_t)(pa + i * sizeof(uint32_t)) | 0xA5A50000u;
        if (fb[i] != want)
            bad++;
    }
    kr = nmx_scanout_free(pa, len);
    if (kr != KERN_SUCCESS)
        bad++;
    printf("Raphaeli scanout selftest: %s (alloc %u bytes at phys 0x%llx, %d bad words)\n",
           bad == 0 ? "PASS" : "FAIL", (unsigned)len, (unsigned long long)pa, bad);
    return bad == 0 ? 0 : -1;
}
