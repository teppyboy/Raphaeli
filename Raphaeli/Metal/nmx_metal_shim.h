/*
 * C ABI seam for a Metal plugin over metal2vulkan-runtime. The runtime is pure Rust with no C ABI yet
 * (deps/metal2vulkan exports no #[no_mangle] symbols and builds no cdylib/staticlib), so this shim has no
 * backend: every entry point reports NMX_METAL_UNSUPPORTED. Do not treat a NULL device as acceleration.
 */
#ifndef NMX_METAL_SHIM_H
#define NMX_METAL_SHIM_H

typedef enum {
    NMX_METAL_OK = 0,
    NMX_METAL_UNSUPPORTED = -1,
} nmx_metal_status;

/* Reports whether a metal2vulkan backend is linked; always 0 until the runtime exposes a C ABI. */
int nmx_metal_backend_available(void);

/* Creates a system default Metal device; always NMX_METAL_UNSUPPORTED with *device_out set to NULL. */
nmx_metal_status nmx_metal_create_device(void **device_out);

#endif /* NMX_METAL_SHIM_H */
