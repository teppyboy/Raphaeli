#include "nmx_metal_shim.h"

#include <stddef.h>

int nmx_metal_backend_available(void)
{
    return 0;
}

nmx_metal_status nmx_metal_create_device(void **device_out)
{
    if (device_out != NULL)
        *device_out = NULL;
    return NMX_METAL_UNSUPPORTED;
}
