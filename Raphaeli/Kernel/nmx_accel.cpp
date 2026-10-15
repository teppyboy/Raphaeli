/*
 * RaphaeliAccel, IOKit side: one IOGraphicsAccelerator2 (Apple's IOAcceleratorFamily2) on every AMD or Intel GPU
 * the Raphaeli kext has claimed, so IOServiceOpen can create acceleration user clients (Metal's path). Same
 * architecture as the reference driver's NMXAccel (research/nvidia-macos-driver/kexts/NVRM/accel, -DNMX_ACCEL):
 * the family binary owns the user-client classes and their selector dispatch; this file only answers the
 * family's factory and config hooks. The vendor objects live in nmx_accel_uc.cpp.
 *
 * v1: opens succeed, everything else is logged and refused honestly — the accel UC objects still own no
 * VRAM allocator and no GPU page tables (the amdgpu driver does); the submit hooks below are wired to its
 * real gfx-ring/fence path (nmx_accel_bridge.c) and are the reusable core until the protocol mapping is proven.
 */
#include "nmx_accel.h"
#include "nmx_port.h"
#include <sys/errno.h>
#include <IOKit/pci/IOPCIDevice.h>

#define AMD_VENDOR 0x1002
#define INTEL_VENDOR 0x8086

/* log the first few of each op, then every 1024th: enough to see traffic, never a log flood */
static inline bool accel_log_sample(unsigned &seen, unsigned first)
{
    unsigned n = seen++;
    return n < first || (n & 1023) == 0;
}

/* ---- the lane contract's submit hooks (v1: real amdgpu path via Override/src/nmx_accel_bridge.c) ------- */

/* errors map to KERN_*; the bridge logs its own details, this side logs the contract surface */
static inline kern_return_t accel_bridge_result(int r)
{
    if (r == 0)
        return KERN_SUCCESS;
    if (r == -ETIME)
        return KERN_OPERATION_TIMED_OUT;
    return KERN_NOT_SUPPORTED;
}

extern "C" kern_return_t nmx_xnu_accel_ring_submit(uint32_t ring, uint64_t ib_addr, uint32_t ib_dw, uint64_t *fence_out)
{
    static unsigned submits;
    if (fence_out)
        *fence_out = 0;
    int r = nmx_accel_bridge_submit(ring, ib_addr, ib_dw, fence_out);
    if (accel_log_sample(submits, 8))
        ACCELLOG("ring_submit: ring %u ib 0x%llx (%u dw) -> 0x%x (%d)", ring,
                 (unsigned long long)ib_addr, ib_dw,
                 accel_bridge_result(r), r);
    return accel_bridge_result(r);
}

extern "C" kern_return_t nmx_xnu_accel_fence_wait(uint64_t fence, uint32_t timeout_ms)
{
    static unsigned waits;
    int r = nmx_accel_bridge_fence_wait(fence, timeout_ms);
    if (accel_log_sample(waits, 8))
        ACCELLOG("fence_wait: fence %llu %u ms -> 0x%x (%d)",
                 (unsigned long long)fence, timeout_ms, accel_bridge_result(r), r);
    return accel_bridge_result(r);
}

/* ---- the accelerator nub -------------------------------------------------------------------------------------- */

RaphaeliAccel *RaphaeliAccel::gAccel = nullptr;

IOService *RaphaeliAccel::probe(IOService *provider, SInt32 *score)
{
    IOPCIDevice *pci = OSDynamicCast(IOPCIDevice, provider);
    uint16_t vendor = pci ? pci->configRead16(kIOPCIConfigVendorID) : 0;
    uint8_t cls = pci ? pci->configRead8(kIOPCIConfigClassCode + 3) : 0;
    if (cls != 0x03 || (vendor != AMD_VENDOR && vendor != INTEL_VENDOR))
        return nullptr;
    return IOGraphicsAccelerator2::probe(provider, score);
}

bool RaphaeliAccel::start(IOService *provider)
{
    IOPCIDevice *pci = OSDynamicCast(IOPCIDevice, provider);
    /* only on a GPU this kext's own driver (Raphaeli, nmx_kext.cpp) runs amdgpu on: it sets the claim after its
       attach thread finished, and re-runs matching on the device then, which offers it here again */
    if (pci == nullptr || pci->getProperty("nmxgpu-claimed") != kOSBooleanTrue) {
        ACCELLOG("start: GPU not claimed by the Raphaeli driver yet - not starting");
        return false;
    }
    bool ok = IOGraphicsAccelerator2::start(provider);
    ACCELLOG("start(%04x:%04x): family start -> %d", pci->configRead16(kIOPCIConfigVendorID),
             pci->configRead16(kIOPCIConfigDeviceID), ok);
    if (ok) {
        gAccel = this;
        registerService();
        enableAccelerator();   /* family gates every resource allocation on this flag */
        ACCELLOG("accelerator up: user clients can open (Metal device for apps; v0 does not execute GPU work)");
    }
    return ok;
}

void RaphaeliAccel::stop(IOService *provider)
{
    if (gAccel == this)
        gAccel = nullptr;
    /* completeForIO/release the stamp page getStampMemory prepared and left retained */
    if (fStamps) {
        fStamps->complete();
        fStamps->release();
        fStamps = nullptr;
    }
    IOGraphicsAccelerator2::stop(provider);
}

uint64_t RaphaeliAccel::getStampMemory(unsigned int *pageBytes)
{
    /* one contiguous page of event stamps; the event machine writes them in writeStamp */
    if (fStamps == nullptr) {
        fStamps = IOBufferMemoryDescriptor::inTaskWithOptions(kernel_task, kIODirectionInOut | kIOMemoryPhysicallyContiguous,
                                                              16384, 4096);
        if (fStamps) {
            fStamps->prepare();
            bzero(fStamps->getBytesNoCopy(), 16384);
        } else
            ACCELLOG("getStampMemory: no contiguous stamp page");
    }
    if (pageBytes)
        *pageBytes = fStamps ? 4096 : 0;
    return (uint64_t)(uintptr_t)fStamps;
}

OSObject *RaphaeliAccel::newEventMachine()
{
    RaphaeliEventMachine *m = OSTypeAlloc(RaphaeliEventMachine);
    return m;
}

OSObject *RaphaeliAccel::createUserGPUTask()  { return raphaeli_accel_new_task(); }
OSObject *RaphaeliAccel::createKernelGPUTask() { return raphaeli_accel_new_task(); }

void RaphaeliAccel::populateAccelConfig(IOAccelConfig *config)
{
    /* the offsets are the family's Sequoia layout (read out of the binary by the reference driver); values say what
       a modest gen12-class device would: caps 15, 8 heads, 16384x16384 textures */
    uint8_t *p = reinterpret_cast<uint8_t *>(config);
    if (p == nullptr)
        return;
    if (((uintptr_t)p & 0xFFF) + 0x70 > 0x1000) {
        ACCELLOG("populateAccelConfig: config crosses a page boundary - refusing to write it");
        return;
    }
    *(uint64_t *)(p + 0x00) = (uint64_t)(uintptr_t)"RaphaeliAccel";
    *(uint32_t *)(p + 0x08) = 0x30844300u;
    *(uint32_t *)(p + 0x0c) = 15u;
    *(uint32_t *)(p + 0x18) = 8u;
    *(uint32_t *)(p + 0x30) = 0x40004000u;
    *(uint32_t *)(p + 0x34) = 0x00008000u;
    *(uint32_t *)(p + 0x38) = 0x00008000u;
    *(uint8_t  *)(p + 0x44) = 0;
    *(uint8_t  *)(p + 0x46) = 1;
    *(uint8_t  *)(p + 0x47) = 1;
    *(uint64_t *)(p + 0x48) = 0x0000001F0000000FULL;
    *(uint64_t *)(p + 0x50) = 0x7FFFFFFF0000001FULL;
    *(uint64_t *)(p + 0x58) = 0x0000000C00000000ULL;
    *(uint32_t *)(p + 0x64) = 0x4Bu;
    *(uint32_t *)(p + 0x28) = 1u;
}

bool RaphaeliAccel::configureDevice(IOPCIDevice *pci)
{
    /* amdgpu (the Raphaeli kext's driver) owns the card; the family asks us to confirm - it already did */
    return true;
}

void RaphaeliAccel::teardownDevice(IOPCIDevice *pci) {}

OSObject *RaphaeliAccel::newDisplayMachine()
{
    RaphaeliDisplayMachine *d = OSTypeAlloc(RaphaeliDisplayMachine);
    return d;
}

OSObject *RaphaeliAccel::newGLContext()    { RaphaeliGLContext *c = OSTypeAlloc(RaphaeliGLContext); return c; }
OSObject *RaphaeliAccel::newCLContext()    { RaphaeliCLContext *c = OSTypeAlloc(RaphaeliCLContext); return c; }
OSObject *RaphaeliAccel::newSurface()      { RaphaeliSurface *s = OSTypeAlloc(RaphaeliSurface); return s; }
OSObject *RaphaeliAccel::new2DContext()    { Raphaeli2DContext *c = OSTypeAlloc(Raphaeli2DContext); return c; }
OSObject *RaphaeliAccel::newVideoContext() { RaphaeliVideoContext *c = OSTypeAlloc(RaphaeliVideoContext); return c; }
OSObject *RaphaeliAccel::newSysMemory()    { RaphaeliSysMemory *m = OSTypeAlloc(RaphaeliSysMemory); return m; }
OSObject *RaphaeliAccel::newVidMemory()    { RaphaeliVidMemory *m = OSTypeAlloc(RaphaeliVidMemory); return m; }
OSObject *RaphaeliAccel::newResource()     { RaphaeliResource *r = OSTypeAlloc(RaphaeliResource); return r; }
OSObject *RaphaeliAccel::newMemoryMap()    { RaphaeliMemoryMap *m = OSTypeAlloc(RaphaeliMemoryMap); return m; }

IOReturn RaphaeliAccel::newUserClient(task_t owningTask, void *securityID, UInt32 type, IOUserClient **handler)
{
    /* the family implements every client type WindowServer/Metal open (device, shared, display-pipe) and returns
       kIOReturnUnsupported for unknown ones - unknown input never reaches a panic through here */
    static unsigned clients;
    IOReturn r = IOGraphicsAccelerator2::newUserClient(owningTask, securityID, type, handler);
    if (accel_log_sample(clients, 12))
        ACCELLOG("newUserClient(type 0x%x) -> 0x%x %s", type, r,
                 (handler && *handler) ? (*handler)->getMetaClass()->getClassName() : "(none)");
    return r;
}

OSDefineMetaClassAndStructors(RaphaeliAccel, IOGraphicsAccelerator2)
