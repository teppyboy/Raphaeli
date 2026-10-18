/*
 * The IOAccelerator lane: an IOGraphicsAccelerator2 (Apple's IOAcceleratorFamily2) per claimed AMD/Intel GPU, so
 * Metal can open acceleration user clients on it. Same shape as the reference driver's NMXAccel
 * (research/nvidia-macos-driver/kexts/NVRM/accel): the family owns the user clients and their selector dispatch;
 * this lane only supplies the vendor objects the family's factories ask for.
 *
 * The family ships no headers, so the class declarations come from the reference's reconstructed ones
 * (Sequoia x86_64, read out of the shipped family binary — vtable order and class sizes are load-bearing there).
 */
#ifndef NMX_ACCEL_H
#define NMX_ACCEL_H

#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOBufferMemoryDescriptor.h>
#include <IOKit/IORangeAllocator.h>

#define ACCELLOG(fmt, ...) IOLog("Raphaeli accel: " fmt "\n", ##__VA_ARGS__)

/* Tahoe changed private IOAcceleratorFamily2 method visibility and several types.
 * The forwarding header is generated from the matching Tahoe SDK/KC outside this
 * repository. Never fall back to the Sequoia private ABI for a Tahoe build. */
#if defined(NM_TAHOE)
# if defined(__has_include)
#  if __has_include("nmx_accel_tahoe_forwarding.h")
#   include "nmx_accel_tahoe_forwarding.h"
#  else
#   error "NM_TAHOE requires generated nmx_accel_tahoe_forwarding.h"
#  endif
# else
#  error "NM_TAHOE requires generated Tahoe accelerator forwarding headers"
# endif
#else
/* The Sequoia-only reconstructed private ABI must never enter a Tahoe translation unit. */
# include "../../research/nvidia-macos-driver/kexts/NVRM/accel/re/IOGraphicsAccelerator2.h"
# include "../../research/nvidia-macos-driver/kexts/NVRM/accel/iofam/IOAccelEventMachineFast2.h"
# include "../../research/nvidia-macos-driver/kexts/NVRM/accel/iofam/IOAccelLegacyDisplayMachine.h"
# include "../../research/nvidia-macos-driver/kexts/NVRM/accel/iofam/IOAccelTask.h"
# include "../../research/nvidia-macos-driver/kexts/NVRM/accel/iofam/IOAccelMemoryMap.h"
# include "../../research/nvidia-macos-driver/kexts/NVRM/accel/iofam/IOAccelResource2.h"
# include "../../research/nvidia-macos-driver/kexts/NVRM/accel/iofam/IOAccelSysMemory.h"
# include "../../research/nvidia-macos-driver/kexts/NVRM/accel/iofam/IOAccelVidMemory.h"
# include "../../research/nvidia-macos-driver/kexts/NVRM/accel/iofam/IOAccelLegacySurface.h"
# include "../../research/nvidia-macos-driver/kexts/NVRM/accel/iofam/IOAccelGLContext2.h"
# include "../../research/nvidia-macos-driver/kexts/NVRM/accel/iofam/IOAccel2DContext2.h"
# include "../../research/nvidia-macos-driver/kexts/NVRM/accel/iofam/IOAccelCLContext2.h"
# include "../../research/nvidia-macos-driver/kexts/NVRM/accel/iofam/IOAccelVideoContext2.h"
#endif

/*
 * The accel submit hooks of the lane contract (v1): the family-side surface every accel-side submit goes
 * through; nmx_accel_bridge.c (Override/src, behind nmx_port.h) runs each one on the amdgpu driver's real
 * ring/fence path — a kernel-internal IB schedule on a gfx ring, dma_fence_wait_timeout for waits. Unknown
 * input never panics; an uninitialized/suspended/detached device maps to KERN_NOT_SUPPORTED.
 */
extern "C" {
kern_return_t nmx_xnu_accel_ring_submit(uint32_t ring, uint64_t ib_addr, uint32_t ib_dw, uint64_t *fence_out);
kern_return_t nmx_xnu_accel_fence_wait(uint64_t fence, uint32_t timeout_ms);
}

/* nmx_accel.cpp — the accelerator nub */
class RaphaeliAccel : public IOGraphicsAccelerator2 {
    OSDeclareDefaultStructors(RaphaeliAccel)
public:
    static RaphaeliAccel *gAccel;
    IOBufferMemoryDescriptor *fStamps = nullptr;
    /* per-client GPU VA task accounting: one IORangeAllocator per client task, handed to the family
       in IOAccelTask::init (which retains it); released here in stop() as the last owner */
    static constexpr unsigned kTaskRanges = 32;
    static IORangeAllocator *fRanges[kTaskRanges];
    OSObject *createTask(const char *who);
    uint64_t  getStampMemory(unsigned int *pageBytes) APPLE_KEXT_OVERRIDE;
    OSObject *newEventMachine() APPLE_KEXT_OVERRIDE;
    OSObject *createUserGPUTask() APPLE_KEXT_OVERRIDE;
    OSObject *createKernelGPUTask() APPLE_KEXT_OVERRIDE;
    void      populateAccelConfig(IOAccelConfig *config) APPLE_KEXT_OVERRIDE;
    bool      configureDevice(IOPCIDevice *pci) APPLE_KEXT_OVERRIDE;
    void      teardownDevice(IOPCIDevice *pci) APPLE_KEXT_OVERRIDE;
    OSObject *newDisplayMachine() APPLE_KEXT_OVERRIDE;
    OSObject *newGLContext() APPLE_KEXT_OVERRIDE;
    OSObject *newCLContext() APPLE_KEXT_OVERRIDE;
    OSObject *newSurface() APPLE_KEXT_OVERRIDE;
    OSObject *new2DContext() APPLE_KEXT_OVERRIDE;
    OSObject *newVideoContext() APPLE_KEXT_OVERRIDE;
    OSObject *newSysMemory() APPLE_KEXT_OVERRIDE;
    OSObject *newVidMemory() APPLE_KEXT_OVERRIDE;
    OSObject *newResource() APPLE_KEXT_OVERRIDE;
    OSObject *newMemoryMap() APPLE_KEXT_OVERRIDE;
    IOReturn  newUserClient(task_t owningTask, void *securityID, UInt32 type, IOUserClient **handler) APPLE_KEXT_OVERRIDE;
    IOService *probe(IOService *provider, SInt32 *score) APPLE_KEXT_OVERRIDE;
    bool      start(IOService *provider) APPLE_KEXT_OVERRIDE;
    void      stop(IOService *provider) APPLE_KEXT_OVERRIDE;
};
/* nmx_accel_uc.cpp — the objects the family's factories ask for */
class RaphaeliEventMachine : public IOAccelEventMachineFast2 {
    OSDeclareDefaultStructors(RaphaeliEventMachine)
public:
    void writeStamp(int stamp, vendevtCommandRec *, unsigned int value) APPLE_KEXT_OVERRIDE;
    void prepareBarrier(vendevtBarrierRec *) APPLE_KEXT_OVERRIDE;
    void completeBarrier(vendevtBarrierRec *) APPLE_KEXT_OVERRIDE;
    void writeBarrierElement(vendevtBarrierRec *, int, unsigned int) APPLE_KEXT_OVERRIDE;
    bool checkGPUProgress() APPLE_KEXT_OVERRIDE;
    bool checkChannelProgress(int) APPLE_KEXT_OVERRIDE;
    void *eventTimeout(int stamp) APPLE_KEXT_OVERRIDE;
};
class RaphaeliDisplayMachine : public IOAccelLegacyDisplayMachine {
    OSDeclareDefaultStructors(RaphaeliDisplayMachine)
public:
    bool displayModeWillChange() APPLE_KEXT_OVERRIDE;
    bool displayModeDidChange() APPLE_KEXT_OVERRIDE;
};
class RaphaeliTask : public IOAccelTask {
    OSDeclareDefaultStructors(RaphaeliTask)
    /* no vendor overrides: the family's own IOAccelTask (init/allocate/freeAllGPUMappings) does the
       task accounting from the IORangeAllocator** RaphaeliAccel hands it; GPU VM stays refused in the
       map (no page tables yet) */
};
class RaphaeliMemoryMap : public IOAccelMemoryMap {
    OSDeclareDefaultStructors(RaphaeliMemoryMap)
public:
    bool commitIntoGPUPageTable() APPLE_KEXT_OVERRIDE;
    void releaseFromGPUPageTable() APPLE_KEXT_OVERRIDE;
    bool updateGPUPageTable() APPLE_KEXT_OVERRIDE;
};
class RaphaeliResource : public IOAccelResource2 {
    OSDeclareDefaultStructors(RaphaeliResource)
public:
    void rebuildPagingBuffer() APPLE_KEXT_OVERRIDE;
    uint64_t getLevelOffset(unsigned char, unsigned char, int *) APPLE_KEXT_OVERRIDE;
    uint64_t getBackingLevelOffset(unsigned char, unsigned char, int *) APPLE_KEXT_OVERRIDE;
    uint64_t calculateIOSurfaceDeviceCacheVRAMBytes(unsigned long long *, unsigned long long *) APPLE_KEXT_OVERRIDE;
    bool addToAperture() APPLE_KEXT_OVERRIDE;
    void removeFromAperture() APPLE_KEXT_OVERRIDE;
    void *getApertureMemoryDescriptor(unsigned long long *) APPLE_KEXT_OVERRIDE;
};
class RaphaeliSysMemory : public IOAccelSysMemory {
    OSDeclareDefaultStructors(RaphaeliSysMemory)
};
class RaphaeliVidMemory : public IOAccelVidMemory {
    OSDeclareDefaultStructors(RaphaeliVidMemory)
public:
    bool allocPhysical() APPLE_KEXT_OVERRIDE;
    void deallocPhysical() APPLE_KEXT_OVERRIDE;
    uint64_t getPhysicalSegment(unsigned long long offset, unsigned long long *len) APPLE_KEXT_OVERRIDE;
    uint64_t fBo = 0;      /* the bridge's pinned GEM BO (opaque handle, freed exactly once) */
    uint64_t fPhys = 0;    /* its stable device address */
    uint64_t fBytes = 0;
};
class RaphaeliSurface : public IOAccelLegacySurface {
    OSDeclareDefaultStructors(RaphaeliSurface)
public:
    void setSyncCommand(unsigned int *, unsigned int &, unsigned int &, _AMDSurfaceSwapSyncOptions const &) const APPLE_KEXT_OVERRIDE;
    void _pure335() APPLE_KEXT_OVERRIDE;
    bool copyFromBuffer(int, int, int, int, unsigned int, unsigned int, IOAccelEvent *, IOAccelResource2 *, IOAccelSysMemory *, unsigned int, unsigned long long, unsigned int) APPLE_KEXT_OVERRIDE;
    bool copyToBuffer(int, int, int, int, unsigned int, unsigned int, IOAccelEvent *, IOAccelResource2 *, IOAccelSysMemory *, unsigned int, unsigned long long, unsigned int) APPLE_KEXT_OVERRIDE;
    void submitSwapCopy(IOAccelEvent *, IOAccelResource2 *, IOAccelResource2 *) APPLE_KEXT_OVERRIDE;
    void shapeSurface(unsigned int, unsigned short, unsigned short) APPLE_KEXT_OVERRIDE;
    uint32_t getDirtyBufferBitsFromPrivateModeBits(unsigned long long) APPLE_KEXT_OVERRIDE;
};
class RaphaeliGLContext : public IOAccelGLContext2 {
    OSDeclareDefaultStructors(RaphaeliGLContext)
public:
    void _pure362() APPLE_KEXT_OVERRIDE;
    void _pure363() APPLE_KEXT_OVERRIDE;
    void _pure364() APPLE_KEXT_OVERRIDE;
    void _pure367() APPLE_KEXT_OVERRIDE;
};
class Raphaeli2DContext : public IOAccel2DContext2 {
    OSDeclareDefaultStructors(Raphaeli2DContext)
public:
    void _pure362() APPLE_KEXT_OVERRIDE;
    void _pure363() APPLE_KEXT_OVERRIDE;
};
class RaphaeliCLContext : public IOAccelCLContext2 {
    OSDeclareDefaultStructors(RaphaeliCLContext)
};
class RaphaeliVideoContext : public IOAccelVideoContext2 {
    OSDeclareDefaultStructors(RaphaeliVideoContext)
};

#endif /* NMX_ACCEL_H */
