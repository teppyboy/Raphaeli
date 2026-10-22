/* The kext's interface to the port (implemented in src/nmx_port.c); plain types only, shared with the C++ side. */
#ifndef NMX_PORT_H
#define NMX_PORT_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
int nmx_port_start(void);
void nmx_port_stop(void);
/* device-node opens still outstanding: the kext must not stop while this is nonzero */
int nmx_port_busy(void);
void *nmx_port_attach(void *iopci);
void *nmx_port_attach_pci(void *iopci);
void nmx_port_detach(void *dev);
int nmx_port_power(void *dev, int on);
int nmx_port_shutdown(void *dev);

/* the accel lane's ring/fence bridge (Override/src/nmx_accel_bridge.c): the kext registers the GPU once its
   driver attached it; the accel contract's hooks (Kernel/nmx_accel.cpp) then submit kernel-internal IBs on its
   gfx rings and wait on the emitted dma_fences. Bridge results are 0 or a negative errno. */
void nmx_accel_bridge_device(void *iopci);
int nmx_accel_bridge_submit(uint32_t ring, uint64_t ib_addr, uint32_t ib_dw, uint64_t *fence_out);
int nmx_accel_bridge_fence_wait(uint64_t fence, uint32_t timeout_ms);
/* the accel lane's memory bridge (Override/src/nmx_accel_bridge.c): real amdgpu GEM backing for the
   accelerator's vendor video memory (RaphaeliVidMemory). alloc pins one kernel BO of 'size' bytes in
   'domain' (AMDGPU_GEM_DOMAIN_*: 2 = GTT, 4 = VRAM) and returns an opaque handle plus its device
   address and kernel mapping; dmap re-reads the device address; free releases it. Results are 0 or a
   negative errno; handles are held by the caller and must be freed exactly once. */
int nmx_accel_bridge_alloc(uint64_t size, uint64_t align, uint32_t domain, uint64_t *bo_out,
                           uint64_t *gpu_addr_out, void **cpu_out);
uint64_t nmx_accel_bridge_dmap(uint64_t bo);
/* Returns 0 when ownership was released; negative errno leaves the BO owned by the caller. */
int nmx_accel_bridge_free(uint64_t bo, uint64_t gpu_addr, void *cpu);
/* per-task GPU VM; handles are opaque and map/unmap return negative errno on failure */
int nmx_accel_bridge_vm_create(uint64_t *vm_out);
int nmx_accel_bridge_vm_destroy(uint64_t vm);
int nmx_accel_bridge_vm_map(uint64_t vm, uint64_t bo, uint64_t va, uint64_t offset, uint64_t size, uint64_t flags);
int nmx_accel_bridge_vm_unmap(uint64_t vm, uint64_t bo, uint64_t va, uint64_t size);
/* client submit: VM-aware and mapped-range-checked; fails closed (-ENOTSUP) until a task VM lifetime exists */
int nmx_accel_bridge_client_submit(uint64_t vm, uint32_t ring, uint64_t ib_addr, uint32_t ib_dw, uint64_t *fence_out);
/* boot-arg selftest (raphaeli-accel-test=1): one trivial IB through the hooks, fence completion logged */
int nmx_accel_selftest(void);

/* the display bridge (override/src/nmx_fb_bridge.c): one scan-out buffer on every lit output of the device */
struct nmx_fb_info {
    int ok;
    uint32_t width, height, pitch;      /* the buffer: XRGB8888, 'pitch' bytes per row */
    uint64_t phys, size;                /* its physical range (contiguous, through the GPU aperture) */
    uint64_t kva;                       /* its kernel mapping */
    uint32_t pclk_khz;                  /* timing of the largest output's mode */
    uint32_t htotal, vtotal, hsync_start, hsync_end, vsync_start, vsync_end;
};
/* before the driver attaches: settings the bridge needs from the driver (scan-out buffers in contiguous VRAM) */
void nmx_fb_before_attach(void);
int nmx_fb_open(void *dev, struct nmx_fb_info *out);
void nmx_fb_close(void *dev);
int nmx_fb_power(void *dev, int on);
#ifdef __cplusplus
}
#endif
#endif
