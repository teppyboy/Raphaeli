/*
 * The Raphaeli accelerator's vendor objects: what Apple's IOAcceleratorFamily2 asks the accelerator for while
 * running its user clients (event machine, GPU VA tasks, memory maps, resources, memories, surfaces, contexts).
 * Mirrors the reference driver's object shape only. AMD surface backing stays fail-closed: the GPU's page tables and
 * GEM/TTM allocator belong to amdgpu, but no AMD-specific private-family ownership/geometry contract is proven.
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

/* GPU VM is intentionally fail-closed until a complete task-lifetime bridge exists. */
bool RaphaeliMemoryMap::commitIntoGPUPageTable()
{
    static unsigned n;
    if (uc_log_sample(n, 8)) ACCELLOG("memory map commit REFUSED - GPU VM bridge disabled");
    return false;
}
void RaphaeliMemoryMap::releaseFromGPUPageTable() {}
bool RaphaeliMemoryMap::updateGPUPageTable() { return false; }
OSDefineMetaClassAndStructors(RaphaeliMemoryMap, IOAccelMemoryMap)

/* ---- resource: surface backing/page-off is deliberately fail-closed ------------------------------------------- */

void RaphaeliResource::rebuildPagingBuffer()
{
    static unsigned n;
    if (uc_log_sample(n, 4)) ACCELLOG("resource rebuildPagingBuffer REFUSED - AMD GEM/TTM surface backing is not mapped");
}
#if !defined(NM_TAHOE)
void RaphaeliResource::pageoff(IOAccelEvent *, bool, bool *completed)
{
    static unsigned n;
    if (completed) *completed = false;
    if (uc_log_sample(n, 8)) ACCELLOG("resource pageoff REFUSED - no AMD GEM/TTM eviction mapping");
}

void RaphaeliResource::pageoff(IOAccelEvent *, bool, bool *completed, unsigned long long)
{
    static unsigned n;
    if (completed) *completed = false;
    if (uc_log_sample(n, 8)) ACCELLOG("resource pageoff(ext) REFUSED - no AMD GEM/TTM eviction mapping");
}
void RaphaeliResource::pageoffIfNeeded(unsigned int, unsigned int)
{
    static unsigned n;
    if (uc_log_sample(n, 8)) ACCELLOG("resource pageoffIfNeeded REFUSED - no AMD GEM/TTM eviction mapping");
}
#endif
uint64_t RaphaeliResource::getLevelOffset(unsigned char, unsigned char, int *mip)
{
    static unsigned n;
    if (mip) *mip = 0;
    if (uc_log_sample(n, 8)) ACCELLOG("resource getLevelOffset REFUSED - AMD surface layout is unverified");
    return 0;
}
uint64_t RaphaeliResource::getBackingLevelOffset(unsigned char, unsigned char, int *mip)
{
    static unsigned n;
    if (mip) *mip = 0;
    if (uc_log_sample(n, 8)) ACCELLOG("resource getBackingLevelOffset REFUSED - AMD surface layout is unverified");
    return 0;
}
uint64_t RaphaeliResource::calculateIOSurfaceDeviceCacheVRAMBytes(unsigned long long *size, unsigned long long *planes)
{
    static unsigned n;
    if (size) *size = 0;
    if (planes) *planes = 1;
    if (uc_log_sample(n, 8)) ACCELLOG("resource VRAM cache size REFUSED - AMD surface layout is unverified");
    return 0;
}
bool RaphaeliResource::addToAperture()
{
    static unsigned n;
    if (uc_log_sample(n, 8)) ACCELLOG("resource addToAperture REFUSED - no AMD GPU VM mapping");
    return false;
}
void RaphaeliResource::removeFromAperture() {}
void *RaphaeliResource::getApertureMemoryDescriptor(unsigned long long *offset)
{
    if (offset) *offset = 0;
    static unsigned n;
    if (uc_log_sample(n, 8)) ACCELLOG("resource getApertureMemoryDescriptor REFUSED - no AMD GEM/TTM aperture mapping");
    return nullptr;
}
OSDefineMetaClassAndStructors(RaphaeliResource, IOAccelResource2)

OSDefineMetaClassAndStructors(RaphaeliSysMemory, IOAccelSysMemory)

/* ---- vid memory: GEM/TTM ownership is known, but the AMD family-to-surface contract is not ------------------ */

bool RaphaeliVidMemory::allocPhysical()
{
    static unsigned n;
    /* Do not reuse the NVIDIA reconstruction's +0x40/+0xc8 ivars. Until AMD evidence identifies the
       allocation length, owner, eviction, and GPU-VA lifecycle, allocating a BO here could leak or expose it. */
    if (uc_log_sample(n, 8))
        ACCELLOG("vid memory allocPhysical REFUSED - AMD GEM/TTM surface backing contract is unverified");
    return false;
}

void RaphaeliVidMemory::deallocPhysical()
{
    static unsigned n;
    if (!fBo)
        return;
    if (uc_log_sample(n, 8)) ACCELLOG("vid memory deallocPhysical(%p): releasing unverified backing", this);
    if (nmx_accel_bridge_free(fBo, fPhys, nullptr) != 0) {
        if (uc_log_sample(n, 8)) ACCELLOG("vid memory deallocPhysical(%p): bridge kept active BO", this);
        return;
    }
    fBo = fPhys = fBytes = 0;
}

uint64_t RaphaeliVidMemory::getPhysicalSegment(unsigned long long offset, unsigned long long *len)
{
    static unsigned n;
    if (len) *len = 0;
    if (!fPhys || offset >= fBytes) {
        if (uc_log_sample(n, 8)) ACCELLOG("vid memory getPhysicalSegment REFUSED - no verified surface backing");
        return 0;
    }
    if (len) *len = fBytes - offset;
    return fPhys + offset;
}
OSDefineMetaClassAndStructors(RaphaeliVidMemory, IOAccelVidMemory)

/* ---- surface: backing is not mapped until the AMD GEM/TTM and GPU-VM contract is proven ----------------------- */

void RaphaeliSurface::setSyncCommand(unsigned int *, unsigned int &s1, unsigned int &s2, _AMDSurfaceSwapSyncOptions const &) const
{
    s1 = s2 = 0;
}
void RaphaeliSurface::_pure335() {}
void RaphaeliSurface::set_shape_backing_length_ext(eIOAccelSurfaceShapeBits, unsigned int, unsigned long long,
                                                    unsigned int, unsigned long long, IOAccelDeviceRegion *,
                                                    unsigned long long)
{
    static unsigned n;
    if (uc_log_sample(n, 8))
        ACCELLOG("surface backing REFUSED - AMD GEM/TTM surface layout and GPU VA mapping are unverified");
}
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
#if defined(NM_TAHOE)
OSDefineMetaClassAndStructors(RaphaeliDisplayPipe, IOAccelLegacyDisplayPipe)
NM_TAHOE_FWD_DEFS
#endif
