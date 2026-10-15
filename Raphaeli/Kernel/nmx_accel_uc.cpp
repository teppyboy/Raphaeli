/*
 * The Raphaeli accelerator's vendor objects: what Apple's IOAcceleratorFamily2 asks the accelerator for while
 * running its user clients (event machine, GPU VA tasks, memory maps, resources, memories, surfaces, contexts).
 * Mirrors the reference driver's stubs (research/nvidia-macos-driver/kexts/NVRM/accel/nvaccel_stubs.h) with the
 * NVRM/RM calls replaced by v0 refusals: this GPU's page tables and VRAM allocator are the amdgpu driver's
 * (nmx_kext.cpp / the DRM layer), and no bridge exists yet, so every mapping op is logged and refused honestly.
 * Nothing here executes GPU work; unknown family input reaches only these virtuals, none of which can panic.
 */
#include "nmx_accel.h"
#include "nmx_port.h"

static inline bool uc_log_sample(unsigned &seen, unsigned first)
{
    unsigned n = seen++;
    return n < first || (n & 1023) == 0;
}

/* ---- event machine: the family's stamp/barret bookkeeping; stamps live in RaphaeliAccel's contiguous page ------- */

void RaphaeliEventMachine::writeStamp(int stamp, vendevtCommandRec *, unsigned int value)
{
    RaphaeliAccel *a = RaphaeliAccel::gAccel;
    if (a && a->fStamps && stamp >= 0 && stamp < 4096) {
        volatile unsigned int *base = (volatile unsigned int *)a->fStamps->getBytesNoCopy();
        if (base)
            base[stamp] = value;
    }
}

void RaphaeliEventMachine::prepareBarrier(vendevtBarrierRec *b)
{
    static unsigned n;
    if (uc_log_sample(n, 4)) ACCELLOG("EM prepareBarrier(%p) - v0, ignored", b);
}
void RaphaeliEventMachine::completeBarrier(vendevtBarrierRec *b)
{
    static unsigned n;
    if (uc_log_sample(n, 4)) ACCELLOG("EM completeBarrier(%p) - v0, ignored", b);
}
void RaphaeliEventMachine::writeBarrierElement(vendevtBarrierRec *b, int i, unsigned int v)
{
    static unsigned n;
    if (uc_log_sample(n, 4)) ACCELLOG("EM writeBarrierElement(%p, %d, %u) - v0, ignored", b, i, v);
}
bool RaphaeliEventMachine::checkGPUProgress() { return true; }
bool RaphaeliEventMachine::checkChannelProgress(int) { return true; }
void *RaphaeliEventMachine::eventTimeout(int stamp)
{
    static unsigned n;
    if (uc_log_sample(n, 4)) ACCELLOG("EM eventTimeout(%d) - no family channels in use, ignored", stamp);
    return nullptr;
}
OSDefineMetaClassAndStructors(RaphaeliEventMachine, IOAccelEventMachineFast2)

/* ---- display machine: mode-change acknowledgements (the panels are RaphaeliFB's; the family only asks) ---------- */

bool RaphaeliDisplayMachine::displayModeWillChange() { return true; }
bool RaphaeliDisplayMachine::displayModeDidChange() { return true; }
OSDefineMetaClassAndStructors(RaphaeliDisplayMachine, IOAccelLegacyDisplayMachine)

/* ---- GPU VA task: the family owns the class; task accounting (VA allocators + family registration) is done
   in RaphaeliAccel::createUserGPUTask, exactly like the proven reference driver's newGPUTask ------------- */

OSDefineMetaClassAndStructors(RaphaeliTask, IOAccelTask)

/* ---- memory map: the family's GART hook; v0 has no page tables, so nothing ever maps ---------------------------- */

bool RaphaeliMemoryMap::commitIntoGPUPageTable()
{
    static unsigned n;
    if (uc_log_sample(n, 8)) ACCELLOG("memory map commit REFUSED - no GPU page tables (v0)");
    return false;
}
void RaphaeliMemoryMap::releaseFromGPUPageTable() {}
bool RaphaeliMemoryMap::updateGPUPageTable() { return false; }
OSDefineMetaClassAndStructors(RaphaeliMemoryMap, IOAccelMemoryMap)

/* ---- resource: the family's paging-buffer and aperture hooks; v0 has no VRAM, so the aperture stays closed ------ */

void RaphaeliResource::rebuildPagingBuffer()
{
    static unsigned n;
    if (uc_log_sample(n, 4)) ACCELLOG("resource rebuildPagingBuffer - nothing to rebuild (v0)");
}
uint64_t RaphaeliResource::getLevelOffset(unsigned char, unsigned char, int *mip)
{
    if (mip) *mip = 0;
    return 0;
}
uint64_t RaphaeliResource::getBackingLevelOffset(unsigned char, unsigned char, int *mip)
{
    if (mip) *mip = 0;
    return 0;
}
uint64_t RaphaeliResource::calculateIOSurfaceDeviceCacheVRAMBytes(unsigned long long *size, unsigned long long *planes)
{
    if (size) *size = 0;
    if (planes) *planes = 1;
    return 0;
}
bool RaphaeliResource::addToAperture()
{
    static unsigned n;
    if (uc_log_sample(n, 8)) ACCELLOG("resource addToAperture REFUSED - no VRAM allocator (v0)");
    return false;
}
void RaphaeliResource::removeFromAperture() {}
void *RaphaeliResource::getApertureMemoryDescriptor(unsigned long long *offset)
{
    if (offset) *offset = 0;
    return nullptr;
}
OSDefineMetaClassAndStructors(RaphaeliResource, IOAccelResource2)

OSDefineMetaClassAndStructors(RaphaeliSysMemory, IOAccelSysMemory)

/* ---- vid memory: real VRAM through the bridge (Override/src/nmx_accel_bridge.c: amdgpu's own kernel GEM
   helper). The object is backed by one pinned GEM BO; the device address is what getPhysicalSegment hands
   out. No GPU page tables exist yet, so the map-side commit still refuses — allocations are real, GPU VM is
   the next lane. Geometry comes from the family's ivars: length at +0x40, phys slot at +0xc8 (reference). */

bool RaphaeliVidMemory::allocPhysical()
{
    static unsigned n;
    const unsigned long long want = *(const volatile unsigned long long *)((const unsigned char *)this + 0x40);
    if (!want)
        return false;
    if (fBo) {   /* already backed: AMD's own shape (false when re-allocating a live allocation) */
        if (uc_log_sample(n, 8)) ACCELLOG("vid memory allocPhysical(%p): already backed by %llu bytes", this, fBytes);
        return false;
    }
    uint64_t bo = 0, addr = 0;
    void *cpu = nullptr;
    int r = nmx_accel_bridge_alloc(want, 4096, 4 /* AMDGPU_GEM_DOMAIN_VRAM */, &bo, &addr, &cpu);
    if (r) {
        if (uc_log_sample(n, 8)) ACCELLOG("vid memory allocPhysical(%p): %llu bytes refused by the bridge (%d)", this, want, r);
        return false;
    }
    fBo = bo;
    fPhys = nmx_accel_bridge_dmap(bo);
    fBytes = want;
    *(volatile unsigned long long *)((unsigned char *)this + 0xc8) = fPhys;   /* the family's phys slot */
    if (uc_log_sample(n, 8))
        ACCELLOG("vid memory allocPhysical(%p): %llu bytes of REAL VRAM - device address 0x%llx (cpu %p)",
                 this, fBytes, (unsigned long long)fPhys, cpu);
    return fPhys != 0;
}

void RaphaeliVidMemory::deallocPhysical()
{
    static unsigned n;
    if (!fBo)
        return;
    if (uc_log_sample(n, 8)) ACCELLOG("vid memory deallocPhysical(%p): releasing %llu bytes", this, fBytes);
    nmx_accel_bridge_free(fBo, fPhys, nullptr);
    fBo = fPhys = fBytes = 0;
    *(volatile unsigned long long *)((unsigned char *)this + 0xc8) = 0;
}

uint64_t RaphaeliVidMemory::getPhysicalSegment(unsigned long long offset, unsigned long long *len)
{
    if (len) *len = 0;
    if (!fPhys || offset >= fBytes)
        return 0;
    if (len) *len = fBytes - offset;
    return fPhys + offset;
}
OSDefineMetaClassAndStructors(RaphaeliVidMemory, IOAccelVidMemory)

/* ---- surface: the compositor's swap path; v0 swaps are logged, never flipped (RaphaeliFB owns the panel) -------- */

void RaphaeliSurface::setSyncCommand(unsigned int *, unsigned int &s1, unsigned int &s2, _AMDSurfaceSwapSyncOptions const &) const
{
    s1 = s2 = 0;
}
void RaphaeliSurface::_pure335() {}
bool RaphaeliSurface::copyFromBuffer(int, int, int, int, unsigned int, unsigned int, IOAccelEvent *, IOAccelResource2 *,
                                     IOAccelSysMemory *, unsigned int, unsigned long long, unsigned int)
{
    static unsigned n;
    if (uc_log_sample(n, 4)) ACCELLOG("surface copyFromBuffer REFUSED - v0");
    return false;
}
bool RaphaeliSurface::copyToBuffer(int, int, int, int, unsigned int, unsigned int, IOAccelEvent *, IOAccelResource2 *,
                                   IOAccelSysMemory *, unsigned int, unsigned long long, unsigned int)
{
    static unsigned n;
    if (uc_log_sample(n, 4)) ACCELLOG("surface copyToBuffer REFUSED - v0");
    return false;
}
void RaphaeliSurface::submitSwapCopy(IOAccelEvent *, IOAccelResource2 *a1, IOAccelResource2 *a2)
{
    static unsigned n;
    if (uc_log_sample(n, 8))
        ACCELLOG("surface submitSwapCopy(%p, %p) logged - no flip engine (v0; WindowServer keeps drawing into RaphaeliFB)",
                 a1, a2);
}
void RaphaeliSurface::shapeSurface(unsigned int mask, unsigned short w, unsigned short h)
{
    static unsigned n;
    if (uc_log_sample(n, 8)) ACCELLOG("surface shapeSurface(mask 0x%x, %u x %u) - buffers shaped by the family", mask, w, h);
}
uint32_t RaphaeliSurface::getDirtyBufferBitsFromPrivateModeBits(unsigned long long bits)
{
    static unsigned n;
    if (uc_log_sample(n, 4)) ACCELLOG("surface getDirtyBufferBitsFromPrivateModeBits(0x%llx) -> 0", (unsigned long long)bits);
    return 0;
}
OSDefineMetaClassAndStructors(RaphaeliSurface, IOAccelLegacySurface)

/* ---- contexts: one per client (GL/2D/CL/video); the family runs the command stream, the pure hooks stay quiet --- */

void RaphaeliGLContext::_pure362() {}
void RaphaeliGLContext::_pure363() {}
void RaphaeliGLContext::_pure364() {}
void RaphaeliGLContext::_pure367() {}
OSDefineMetaClassAndStructors(RaphaeliGLContext, IOAccelGLContext2)

void Raphaeli2DContext::_pure362() {}
void Raphaeli2DContext::_pure363() {}
OSDefineMetaClassAndStructors(Raphaeli2DContext, IOAccel2DContext2)

OSDefineMetaClassAndStructors(RaphaeliCLContext, IOAccelCLContext2)
OSDefineMetaClassAndStructors(RaphaeliVideoContext, IOAccelVideoContext2)
