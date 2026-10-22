/* Host test for Raphaeli/Metal/nmx_metal_shim.c: the shim must never report a device or backend. */
#include <stdio.h>
#include <stddef.h>

#include "../../Raphaeli/Metal/nmx_metal_shim.h"

static int failures;

#define EXPECT(cond, what)                                   \
    do {                                                     \
        if (cond) {                                          \
            printf("ok    %s\n", what);                      \
        } else {                                             \
            printf("FAIL  %s\n", what);                      \
            failures++;                                      \
        }                                                    \
    } while (0)

int main(void)
{
    void *dev = (void *)&failures;
    nmx_metal_status st = nmx_metal_create_device(&dev);

    EXPECT(nmx_metal_backend_available() == 0, "backend-unavailable");
    EXPECT(st == NMX_METAL_UNSUPPORTED, "create-device-unsupported");
    EXPECT(dev == NULL, "create-device-null-out");
    EXPECT(nmx_metal_create_device(NULL) == NMX_METAL_UNSUPPORTED, "create-device-null-arg-unsupported");

    if (failures) {
        printf("nmx_metal_shim tests: %d failed\n", failures);
        return 1;
    }
    printf("nmx_metal_shim tests: all passed\n");
    return 0;
}
