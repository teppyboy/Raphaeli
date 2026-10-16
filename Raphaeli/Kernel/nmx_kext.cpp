/*
 * The kext: one IOService per AMD or Intel GPU it is allowed to drive (amdgpu and i915 share one DRM core and one
 * port layer here). Compiled with Apple's headers only; everything else is reached through nmx_port.h.
 *
 * Opt-in only, per vendor. The service matches every AMD and Intel display-class device but declines in probe()
 * unless the user asked for that vendor: boot argument raphaeli-amd=1 / raphaeli-intel=1, or the device property
 * "raphaeli-gpu" (set through the bootloader's DeviceProperties). Without that, the device keeps whatever driver macOS
 * gives it. Taking a GPU that is lighting the boot display resets its display engine, so the opt-in is per user,
 * never a default.
 *
 * The port (the FreeBSD/Linux layer and the AMD driver) starts with the first device and stops when the kext
 * unloads; unloading is refused while any process still has a GPU device node open.
 */
#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOLocks.h>
#include <IOKit/IONVRAM.h>
#include <IOKit/pci/IOPCIDevice.h>
#include <libkern/c++/OSBoolean.h>
#include <libkern/c++/OSData.h>
#include <mach/kmod.h>
#include <pexpert/pexpert.h>
#include <kern/thread.h>
#include "nmx_port.h"
#include "nmx_xnu.h"

#define AMD_VENDOR 0x1002
#define INTEL_VENDOR 0x8086

/* scanout lane self-check (override/display/nmx_scanout_selftest.c); inert unless the boot-arg
   raphaeli-scanout-test=1 is set, in which case it allocates/pattern-checks/frees one frame */
extern "C" int nmx_scanout_selftest(void);

class Raphaeli : public IOService {
    OSDeclareDefaultStructors(Raphaeli)
    void *dev_;
    IOPCIDevice *pci_;
    volatile int attach_;   /* 0 = attach pending on its thread, 1 = attached, -1 = not attached */
    bool pm_;
    static void attachThread(void *arg, wait_result_t);
    void attachNow();
public:
    IOService *probe(IOService *provider, SInt32 *score) override;
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
    IOReturn setPowerState(unsigned long state, IOService *device) override;
    void systemWillShutdown(IOOptionBits spec) override;
};
OSDefineMetaClassAndStructors(Raphaeli, IOService)

static IOLock *g_lock;
static bool g_started;
static int g_devices;

static bool opted_in(IOPCIDevice *pci, uint16_t vendor)
{
    int v = 0;
    /* the boot picker's "Start once without NVIDIA driver" entry (-nvoff) parks every Raphaeli GPU driver for that start */
    if (PE_parse_boot_argn("-nvoff", &v, sizeof(v)))
        return false;
    if (PE_parse_boot_argn(vendor == AMD_VENDOR ? "raphaeli-amd" : "raphaeli-intel", &v, sizeof(v)) && v != 0)
        return true;
    OSObject *p = pci->getProperty("raphaeli-gpu");
    if (OSBoolean *b = OSDynamicCast(OSBoolean, p))
        return b->isTrue();
    if (OSData *d = OSDynamicCast(OSData, p))
        return d->getLength() > 0 && ((const uint8_t *)d->getBytesNoCopy())[0] != 0;
    return false;
}

IOService *Raphaeli::probe(IOService *provider, SInt32 *score)
{
    IOPCIDevice *pci = OSDynamicCast(IOPCIDevice, provider);
    uint16_t vendor = pci ? pci->configRead16(kIOPCIConfigVendorID) : 0;
    if (vendor != AMD_VENDOR && vendor != INTEL_VENDOR)
        return nullptr;
    if (!opted_in(pci, vendor)) {
        IOLog("Raphaeli checkpoint: probe parked (opt-in absent or -nvoff)\n");
        return nullptr;     /* not asked for: leave the device to macOS */
    }
    return IOService::probe(provider, score);
}

bool Raphaeli::start(IOService *provider)
{
    IOPCIDevice *pci = OSDynamicCast(IOPCIDevice, provider);
    if (pci == nullptr || g_lock == nullptr || !IOService::start(provider))
        return false;
    /* audit P1: do not attach without a mapped MMIO aperture; a vGPU with a trapped/zero BAR0 would
       otherwise run amdgpu discovery against garbage */
    uint64_t bar0_phys = 0, bar0_size = 0;
    int bar0_io = 0;
    if (nmx_xnu_pci_bar_info(pci, kIOPCIConfigBaseAddress0, &bar0_phys, &bar0_size, &bar0_io) != 1
        || bar0_size == 0 || bar0_io) {
        IOLog("Raphaeli GPU: no usable MMIO BAR0 (size %llu, io %d); this GPU stays with macOS\n",
              (unsigned long long)bar0_size, bar0_io);
        IOService::stop(provider);
        return false;
    }
    /* audit P1-2: never attach with dead interrupts; only MSI is implemented, so require at least one
       message-signalled source (nmx_xnu_pci_msi_count can legitimately report 0 in a VM) */
    if (nmx_xnu_pci_msi_count(pci) <= 0) {
        IOLog("Raphaeli GPU: MSI unavailable, MSI-X/legacy fallback not implemented; this GPU stays with macOS\n");
        IOService::stop(provider);
        return false;
    }
    IOLog("Raphaeli checkpoint: PCI checks passed; starting port layer\n");
    IOLockLock(g_lock);
    if (!g_started) {
        int err = nmx_port_start();
        if (err) {
            IOLockUnlock(g_lock);
            IOLog("Raphaeli GPU: the driver layer did not start (%d)\n", err);
            IOService::stop(provider);
            return false;
        }
        g_started = true;
        IOLog("Raphaeli checkpoint: port layer started\n");
        nmx_scanout_selftest();
    }
    g_devices++;
    IOLockUnlock(g_lock);

    /*
     * amdgpu, i915 and xe load firmware while they attach. During boot matching that read would come before the root and
     * Data volumes are mounted, and mounting waits for matching to settle: the Mac would stop at the logo (seen with the
     * NPU kext on the same layer, 10-11). The attach runs on its own thread once the firmware folder exists; the firmware
     * framebuffer keeps the screen until then.
     */
    pci_ = pci;
    dev_ = nullptr;
    pm_ = false;
    attach_ = 0;
    retain();
    thread_t t = THREAD_NULL;
    if (kernel_thread_start(&Raphaeli::attachThread, this, &t) != KERN_SUCCESS) {
        IOLog("Raphaeli GPU: could not start the attach thread\n");
        attach_ = -1;
        release();
        return true;
    }
    thread_deallocate(t);
    return true;
}

void Raphaeli::attachThread(void *arg, wait_result_t)
{
    Raphaeli *self = (Raphaeli *)arg;
    self->attachNow();
    self->release();
}

/*
 * Boot guard, as in NMXNPU: the NPU kext on this layer panicked 7 s into every start until its boot argument was
 * removed from Linux. The attach, the modeset and the hand-over to macOS run between setting an NVRAM marker
 * and clearing it; a start that finds the marker still set follows an attach that never returned (a panic or a hang),
 * so this GPU stays with macOS and the driver says so. Turning the test driver off and on in the app clears it.
 */
static const char *const kAttachMarker = "raphaeli-gpu-attaching";

static IODTNVRAM *nmx_nvram()
{
    IORegistryEntry *e = IORegistryEntry::fromPath("/options", gIODTPlane);
    IODTNVRAM *n = OSDynamicCast(IODTNVRAM, e);
    if (n == nullptr && e != nullptr)
        e->release();
    return n;
}

static bool nmx_marker_set()
{
    IODTNVRAM *n = nmx_nvram();
    if (n == nullptr)
        return false;
    OSObject *v = n->copyProperty(kAttachMarker);
    bool set = v != nullptr;
    if (v)
        v->release();
    n->release();
    return set;
}

static void nmx_marker_write(bool on)
{
    IODTNVRAM *n = nmx_nvram();
    if (n == nullptr) {
        IOLog("Raphaeli GPU: no NVRAM; the boot guard is off\n");
        return;
    }
    const OSSymbol *k = OSSymbol::withCString(kAttachMarker);
    if (k != nullptr) {
        if (on) {
            OSData *d = OSData::withBytes("1", 1);
            if (d == nullptr || !n->setProperty(k, d))
                IOLog("Raphaeli GPU: could not set the boot guard\n");
            if (d)
                d->release();
        } else {
            n->removeProperty(k);
        }
        k->release();
    }
    n->sync();
    n->release();
}

void Raphaeli::attachNow()
{
    IOLog("Raphaeli checkpoint: attach thread entered\n");
    int err = nmx_xnu_wait_firmware_root(300);
    if (err) {
        IOLog("Raphaeli GPU: the firmware folder never appeared (%d); this GPU stays with macOS\n", err);
        attach_ = -1;
        return;
    }
    if (nmx_marker_set()) {
        IOLog("Raphaeli GPU: the last attach of %04x:%04x never returned (the Mac stopped or restarted); this GPU stays "
              "with macOS. Send logs, then turn the test driver off and on to try again\n",
              pci_->configRead16(kIOPCIConfigVendorID), pci_->configRead16(kIOPCIConfigDeviceID));
        setProperty("raphaeli-gpu-state", "parked: the last attach never returned");
        attach_ = -1;
        return;
    }
    IOLog("Raphaeli checkpoint: setting attach guard\n");
    nmx_marker_write(true);
    IOLog("Raphaeli checkpoint: entering amdgpu attach\n");
    dev_ = nmx_port_attach(pci_);
    IOLog("Raphaeli checkpoint: amdgpu attach returned (%s)\n", dev_ ? "device" : "no device");
    if (dev_ == nullptr) {
        nmx_marker_write(false);
        IOLog("Raphaeli GPU: no driver took %04x:%04x\n", pci_->configRead16(kIOPCIConfigVendorID),
              pci_->configRead16(kIOPCIConfigDeviceID));
        attach_ = -1;
        return;
    }

    static IOPMPowerState states[2] = {
        { kIOPMPowerStateVersion1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        { kIOPMPowerStateVersion1, kIOPMPowerOn, kIOPMPowerOn, kIOPMPowerOn, 0, 0, 0, 0, 0, 0, 0, 0 },
    };
    IOLog("Raphaeli checkpoint: initializing power management\n");
    PMinit();
    pci_->joinPMtree(this);
    registerPowerDriver(this, states, 2);
    pm_ = true;
    registerService();
    /* NMXAccel (the Metal accelerator for this GPU) starts only on a device this driver has claimed; it declined while
       the claim was pending, so matching on the device runs again now that it is set */
    IOLog("Raphaeli checkpoint: publishing framebuffer/accelerator claim\n");
    pci_->setProperty("nmxgpu-claimed", kOSBooleanTrue);
    pci_->registerService();
    nmx_marker_write(false);
    IOLog("Raphaeli GPU: driving %04x:%04x\n", pci_->configRead16(kIOPCIConfigVendorID),
          pci_->configRead16(kIOPCIConfigDeviceID));
    OSSynchronizeIO();
    /* the accel ring bridge serves the driver that just attached (nmx_accel_bridge.c); the boot-arg
       selftest (raphaeli-accel-test=1) then pushes one trivial IB through the hooks and waits on it */
    nmx_accel_bridge_device(pci_);
    nmx_accel_selftest();
    attach_ = 1;
    IOLog("Raphaeli checkpoint: attach completed\n");
}

void Raphaeli::stop(IOService *provider)
{
    /* an attach still running on its thread finishes first (it holds a reference on this object meanwhile) */
    for (int i = 0; attach_ == 0 && i < 6000; i++)
        IOSleep(100);
    provider->removeProperty("nmxgpu-claimed");
    if (pm_)
        PMstop();
    pm_ = false;
    nmx_port_detach(dev_);
    dev_ = nullptr;
    IOLockLock(g_lock);
    g_devices--;
    IOLockUnlock(g_lock);
    IOService::stop(provider);
}

/* state 0 = sleep, 1 = on */
IOReturn Raphaeli::setPowerState(unsigned long state, IOService *device)
{
    if (dev_ != nullptr) {
        int err = nmx_port_power(dev_, state != 0);
        if (err)
            IOLog("Raphaeli GPU: %s returned %d\n", state ? "resume" : "suspend", err);
    }
    return kIOPMAckImplied;
}

void Raphaeli::systemWillShutdown(IOOptionBits spec)
{
    if (dev_ != nullptr)
        nmx_port_shutdown(dev_);
    IOService::systemWillShutdown(spec);
}

/* ---- module start/stop: the stop refuses while device nodes are open ------------------------------------------------- */

extern "C" {
kern_return_t nmx_kmod_start(kmod_info_t *ki, void *data);
kern_return_t nmx_kmod_stop(kmod_info_t *ki, void *data);
}

kern_return_t nmx_kmod_start(kmod_info_t *ki, void *data)
{
    IOLog("Raphaeli checkpoint: module start entered\n");
    g_lock = IOLockAlloc();
    IOLog("Raphaeli checkpoint: module start %s\n", g_lock ? "ready" : "failed");
    return g_lock ? KERN_SUCCESS : KERN_FAILURE;
}

kern_return_t nmx_kmod_stop(kmod_info_t *ki, void *data)
{
    IOLockLock(g_lock);
    if (g_started) {
        if (g_devices > 0 || nmx_port_busy() > 0) {
            IOLockUnlock(g_lock);
            IOLog("Raphaeli GPU: still in use; not unloading\n");
            return KERN_FAILURE;
        }
        nmx_port_stop();
        g_started = false;
    }
    IOLockUnlock(g_lock);
    IOLockFree(g_lock);
    g_lock = nullptr;
    return KERN_SUCCESS;
}

/* libkmod's entry points; they call _realmain/_antimain below */
extern "C" {
kern_return_t _start(kmod_info_t *ki, void *data);
kern_return_t _stop(kmod_info_t *ki, void *data);
KMOD_EXPLICIT_DECL(me.tretrauit.raphaeli, "1.0.0", _start, _stop)
__private_extern__ kmod_start_func_t *_realmain = nmx_kmod_start;
__private_extern__ kmod_stop_func_t *_antimain = nmx_kmod_stop;
}
