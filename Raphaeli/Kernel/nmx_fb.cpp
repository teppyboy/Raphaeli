/*
 * The display path: a real IOFramebuffer that matches the GPU's IOPCIDevice directly (Info.plist personality,
 * added by the integration lane) and backs every pixel in a scan-out buffer from nmx_scanout_alloc
 * (bsdcompat/src/nmx_scanout.c, scanout lane). WindowServer draws into it and the GPU's display engine scans it
 * out; there is no copy. It attaches only when the BAR0 gate (the same one Raphaeli::start() uses) passes and the
 * scanout allocation succeeds; otherwise the firmware framebuffer keeps the screen.
 *
 * One mode (panel-native when the VBIOS carries a readable EDID, else the documented 1920x1080@60 placeholder in
 * nmx_fb_internal.h), XRGB8888. The IOFramebuffer behaviour (one fixed mode, timing, power acknowledged at once,
 * the colour answers WindowServer asks, a 60 Hz timer as the VBL until the display interrupt is wired) is the same
 * as NMIntelFB's, which met the same WindowServer.
 */
#include <IOKit/IOLib.h>
#include <IOKit/graphics/IOFramebuffer.h>
#include <IOKit/IODeviceMemory.h>
#include <IOKit/pci/IOPCIDevice.h>
#include <kern/thread_call.h>
#include "nmx_xnu.h"
#include "nmx_fb_internal.h"

#define FBLOG(fmt, ...) IOLog("Raphaeli display: " fmt "\n", ##__VA_ARGS__)

static IOPMPowerState kFbPowerStates[2] = {
    { kIOPMPowerStateVersion1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    { kIOPMPowerStateVersion1, kIOPMDeviceUsable, kIOPMPowerOn, kIOPMPowerOn, 0, 0, 0, 0, 0, 0, 0, 0 },
};

static uint32_t pitchFor(uint32_t width)
{
    return nmx_fb_pitch(width);
}

/*
 * The panel's native timing, read out of the VBIOS the PCI ROM BAR maps (nmx_xnu_pci_rom also falls back to the
 * vbios/rom DeviceProperties): the first EDID block with a valid checksum and a sane detailed timing wins
 * (nmx_fb_edid_timing in nmx_fb_internal.h). Anything unreadable or malformed leaves the documented
 * 1920x1080@60 placeholder.
 */
static NMXFbMode fbMode(IOService *provider)
{
    NMXFbMode m = { NMX_FB_DEFAULT_WIDTH, NMX_FB_DEFAULT_HEIGHT, pitchFor(NMX_FB_DEFAULT_WIDTH),
                    NMX_FB_DEFAULT_PCLK_HZ, NMX_FB_DEFAULT_HBLANK, NMX_FB_DEFAULT_VBLANK,
                    NMX_FB_DEFAULT_HSYNC_OFF, NMX_FB_DEFAULT_HSYNC_PW, NMX_FB_DEFAULT_VSYNC_OFF,
                    NMX_FB_DEFAULT_VSYNC_PW };
    const size_t kRomMax = 128 * 1024;
    uint8_t *rom = (uint8_t *)IOMalloc(kRomMax);
    if (rom == nullptr)
        return m;
    size_t n = nmx_xnu_pci_rom(provider, rom, kRomMax);
    static const uint8_t kEdidHeader[8] = { 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };
    for (size_t i = 0; n >= 128 && i + 128 <= n; i++) {
        if (memcmp(rom + i, kEdidHeader, sizeof(kEdidHeader)) != 0)
            continue;
        if (nmx_fb_edid_timing(rom + i, &m))   /* corrupted/insane block: keep scanning */
            break;
    }
    IOFree(rom, kRomMax);
    return m;
}

class RaphaeliFB : public IOFramebuffer {
    OSDeclareDefaultStructors(RaphaeliFB)
    NMXFbMode fMode = {};
    vm_offset_t fPhys = 0;
    vm_offset_t fKern = 0;
    vm_size_t fMapped = 0;
    uint32_t fRefresh16 = 60 << 16;
    uint64_t fFrameNs = 16666667ull;
    struct Irq { IOFBInterruptProc proc = nullptr; OSObject *target = nullptr; void *ref = nullptr; };
    Irq fVbl, fConnect;
    thread_call_t fVblTimer = nullptr;
    uint64_t fVblNext = 0;
    volatile bool fStopping = false;

    static void vblFire(thread_call_param_t p0, thread_call_param_t) {
        RaphaeliFB *me = (RaphaeliFB *)p0;
        if (me->fStopping) return;
        if (me->fVbl.proc) me->fVbl.proc(me->fVbl.target, me->fVbl.ref);
        uint64_t period;
        nanoseconds_to_absolutetime(me->fFrameNs, &period);
        uint64_t now = mach_absolute_time();
        me->fVblNext = (me->fVblNext && me->fVblNext + period > now) ? me->fVblNext + period : now + period;
        thread_call_enter_delayed(me->fVblTimer, me->fVblNext);
    }

public:
    bool initWith(const NMXFbMode &mode) {
        if (!init()) return false;
        fMode = mode;
        uint64_t htotal = (uint64_t)mode.width + mode.hblank;
        uint64_t vtotal = (uint64_t)mode.height + mode.vblank;
        if (mode.pclk_hz && htotal > mode.width && vtotal > mode.height) {
            uint64_t mhz = mode.pclk_hz * 1000 / (htotal * vtotal);   /* milli-Hz */
            if (mhz >= 20000 && mhz <= 500000) {
                fRefresh16 = (uint32_t)((mhz << 16) / 1000);
                fFrameNs = 1000000000000ull / mhz;
            }
        }
        return true;
    }

    bool start(IOService *provider) override {
        IOPCIDevice *pci = OSDynamicCast(IOPCIDevice, provider);
        uint64_t bar0_phys, bar0_size;
        int bar0_io;
        /* the same gate as Raphaeli::start(): without a usable MMIO BAR0 there is nothing to display on */
        if (pci == nullptr
            || nmx_xnu_pci_bar_info(pci, kIOPCIConfigBaseAddress0, &bar0_phys, &bar0_size, &bar0_io) != 1
            || bar0_size == 0 || bar0_io) {
            FBLOG("no usable MMIO BAR0; this display stays with the firmware framebuffer");
            return false;
        }
        fMode = fbMode(provider);
        vm_size_t want = (vm_size_t)fMode.pitch * fMode.height;
        /* the scanout lane owns the buffer (bsdcompat/src/nmx_scanout.c); no buffer, no framebuffer */
        if (nmx_scanout_alloc(want, &fPhys, &fKern, &fMapped) != KERN_SUCCESS || fMapped < want) {
            FBLOG("scanout allocation failed; this display stays with the firmware framebuffer");
            fPhys = 0; fKern = 0; fMapped = 0;
            return false;
        }
        if (!IOFramebuffer::start(provider)) {
            nmx_scanout_free(fPhys, fMapped);
            fPhys = 0; fKern = 0; fMapped = 0;
            return false;
        }
        PMinit();
        provider->joinPMtree(this);
        registerPowerDriver(this, kFbPowerStates, 2);
        fVblTimer = thread_call_allocate(vblFire, this);
        if (fVblTimer) {
            uint64_t d;
            clock_interval_to_deadline((uint32_t)(fFrameNs / 1000), kMicrosecondScale, &d);
            fVblNext = d;
            thread_call_enter_delayed(fVblTimer, d);
        }
        FBLOG("framebuffer %ux%u at %u.%02u Hz", fMode.width, fMode.height, fRefresh16 >> 16,
              ((fRefresh16 & 0xFFFF) * 100) >> 16);
        return true;
    }

    void stop(IOService *provider) override {
        fStopping = true;
        /* thread_call_cancel_wait is not exported to kexts: cancel and retry the free until the callback is out */
        if (fVblTimer) {
            thread_call_cancel(fVblTimer);
            while (!thread_call_free(fVblTimer)) { thread_call_cancel(fVblTimer); IOSleep(5); }
            fVblTimer = nullptr;
        }
        if (fMapped) {
            nmx_scanout_free(fPhys, fMapped);
            fPhys = 0; fKern = 0; fMapped = 0;
        }
        IOFramebuffer::stop(provider);
    }

    IOReturn enableController() override { return kIOReturnSuccess; }
    bool isConsoleDevice() override { return true; }
    IODeviceMemory *getApertureRange(IOPixelAperture aperture) override {
        if (aperture != kIOFBSystemAperture) return nullptr;
        return IODeviceMemory::withRange(fPhys, (IOPhysicalLength)fMode.pitch * fMode.height);
    }
    IODeviceMemory *getVRAMRange() override { return IODeviceMemory::withRange(fPhys, fMapped); }
    const char *getPixelFormats() override { return IO32BitDirectPixels "\0"; }
    IOItemCount getDisplayModeCount() override { return 1; }
    IOReturn getDisplayModes(IODisplayModeID *modes) override { modes[0] = 1; return kIOReturnSuccess; }
    IOReturn getInformationForDisplayMode(IODisplayModeID mode, IODisplayModeInformation *info) override {
        if (mode != 1 || !info) return kIOReturnBadArgument;
        bzero(info, sizeof(*info));
        info->nominalWidth = fMode.width;
        info->nominalHeight = fMode.height;
        info->refreshRate = fRefresh16;
        info->flags = kDisplayModeValidFlag | kDisplayModeSafeFlag | kDisplayModeDefaultFlag;
        return kIOReturnSuccess;
    }
    UInt64 getPixelFormatsForDisplayMode(IODisplayModeID, IOIndex) override { return 0; }
    IOReturn getPixelInformation(IODisplayModeID mode, IOIndex depth, IOPixelAperture aperture,
                                 IOPixelInformation *pi) override {
        if (mode != 1 || depth != 0 || aperture != kIOFBSystemAperture || !pi) return kIOReturnUnsupportedMode;
        bzero(pi, sizeof(*pi));
        pi->bytesPerRow = fMode.pitch;
        pi->bitsPerPixel = NMX_FB_BPP;
        pi->pixelType = kIORGBDirectPixels;
        pi->componentCount = 3;
        pi->bitsPerComponent = 8;
        pi->componentMasks[0] = 0x00FF0000;
        pi->componentMasks[1] = 0x0000FF00;
        pi->componentMasks[2] = 0x000000FF;
        strlcpy(pi->pixelFormat, IO32BitDirectPixels, sizeof(pi->pixelFormat));
        pi->activeWidth = fMode.width;
        pi->activeHeight = fMode.height;
        return kIOReturnSuccess;
    }
    IOReturn getCurrentDisplayMode(IODisplayModeID *mode, IOIndex *depth) override {
        *mode = 1; *depth = 0; return kIOReturnSuccess;
    }
    IOReturn getStartupDisplayMode(IODisplayModeID *mode, IOIndex *depth) override { return getCurrentDisplayMode(mode, depth); }
    /* without a timing, WindowServer shows the display at 0.00 Hz (seen with NMIntelFB) */
    IOReturn getTimingInfoForDisplayMode(IODisplayModeID mode, IOTimingInformation *info) override {
        if (mode != 1 || !info) return kIOReturnUnsupportedMode;
        bzero(info, sizeof(*info));
        info->appleTimingID = kIOTimingIDInvalid;
        const NMXFbMode &t = fMode;
        if (!t.pclk_hz || t.hblank == 0 || t.vblank == 0) return kIOReturnSuccess;
        IODetailedTimingInformationV2 &d = info->detailedInfo.v2;
        d.pixelClock = d.minPixelClock = d.maxPixelClock = t.pclk_hz;
        d.horizontalActive = t.width;
        d.horizontalBlanking = t.hblank;
        d.horizontalSyncOffset = t.hsync_off;
        d.horizontalSyncPulseWidth = t.hsync_pw;
        d.verticalActive = t.height;
        d.verticalBlanking = t.vblank;
        d.verticalSyncOffset = t.vsync_off;
        d.verticalSyncPulseWidth = t.vsync_pw;
        info->flags = kIODetailedTimingValid;
        return kIOReturnSuccess;
    }
    IOReturn setDisplayMode(IODisplayModeID mode, IOIndex depth) override {
        return (mode == 1 && depth == 0) ? kIOReturnSuccess : kIOReturnUnsupported;
    }
    IOItemCount getConnectionCount() override { return 1; }
    IOReturn registerForInterruptType(IOSelect type, IOFBInterruptProc proc, OSObject *target, void *ref,
                                      void **iref) override {
        if (type == kIOFBVBLInterruptType) { fVbl = { proc, target, ref }; if (iref) *iref = &fVbl; return kIOReturnSuccess; }
        if (type == kIOFBConnectInterruptType) { fConnect = { proc, target, ref }; if (iref) *iref = &fConnect; return kIOReturnSuccess; }
        return kIOReturnUnsupported;
    }
    IOReturn unregisterInterrupt(void *) override { return kIOReturnSuccess; }
    IOReturn setInterruptState(void *, UInt32) override { return kIOReturnSuccess; }
    IOReturn setGammaTable(UInt32, UInt32, UInt32, void *) override { return kIOReturnSuccess; }
    IOReturn setGammaTable(UInt32, UInt32, UInt32, void *, bool) override { return kIOReturnSuccess; }
    IOReturn setCLUTWithEntries(IOColorEntry *, UInt32, UInt32, IOOptionBits) override { return kIOReturnSuccess; }
    IOReturn setApertureEnable(IOPixelAperture, IOOptionBits) override { return kIOReturnSuccess; }
    IOReturn setStartupDisplayMode(IODisplayModeID, IOIndex) override { return kIOReturnSuccess; }
    /* power acknowledged at once; left to IOFramebuffer it waits on a shared thread (seen with NVRMFB) */
    IOReturn setPowerState(unsigned long ordinal, IOService *) override {
        handleEvent(ordinal ? kIOFBNotifyDidPowerOn : kIOFBNotifyWillPowerOff);
        return kIOPMAckImplied;
    }
    IOReturn setAttribute(IOSelect attribute, uintptr_t value) override {
        if (attribute == kIOWindowServerActiveAttribute) return kIOReturnSuccess;
        if (attribute == kIOPowerAttribute) {
            /* display sleep drops the outputs; wake lights them again with the same buffer */
            if (value) {
                IOReturn r = IOFramebuffer::setAttribute(attribute, value);
                handleEvent(kIOFBNotifyDidPowerOn);
                return r == kIOReturnUnsupported ? kIOReturnSuccess : r;
            }
            handleEvent(kIOFBNotifyWillPowerOff);
            IOReturn r = IOFramebuffer::setAttribute(attribute, value);
            return r == kIOReturnUnsupported ? kIOReturnSuccess : r;
        }
        return IOFramebuffer::setAttribute(attribute, value);
    }
    IOReturn setAttributeForConnection(IOIndex idx, IOSelect attribute, uintptr_t value) override {
        switch (attribute) {
        case kConnectionPower: case kConnectionColorModesSupported: case kConnectionColorDepthsSupported:
        case kConnectionControllerColorDepth: case kConnectionControllerDepthsSupported: case kConnectionColorMode:
        case kConnectionDisplayFlags: case kConnectionFlags:
            return kIOReturnSuccess;
        default:
            return IOFramebuffer::setAttributeForConnection(idx, attribute, value);
        }
    }
    IOReturn connectFlags(IOIndex, IODisplayModeID, IOOptionBits *flags) override {
        if (flags) *flags = kDisplayModeValidFlag | kDisplayModeSafeFlag | kDisplayModeDefaultFlag;
        return kIOReturnSuccess;
    }
    IOReturn getAttribute(IOSelect attribute, uintptr_t *value) override {
        if (attribute == kIOWindowServerActiveAttribute) { if (value) *value = 1; return kIOReturnSuccess; }
        return IOFramebuffer::getAttribute(attribute, value);
    }
    IOReturn getAttributeForConnection(IOIndex idx, IOSelect attr, uintptr_t *value) override {
        if (idx != 0 || !value) return kIOReturnBadArgument;
        switch (attr) {
        case kConnectionEnable: case kConnectionCheckEnable: *value = 1; return kIOReturnSuccess;
        case kConnectionColorModesSupported: case kConnectionColorMode: *value = 0x00000001; return kIOReturnSuccess;
        case kConnectionColorDepthsSupported: case kConnectionControllerColorDepth: case kConnectionControllerDepthsSupported:
            *value = 0x00000002; return kIOReturnSuccess;
        default: return IOFramebuffer::getAttributeForConnection(idx, attr, value);
        }
    }
};
OSDefineMetaClassAndStructors(RaphaeliFB, IOFramebuffer)
