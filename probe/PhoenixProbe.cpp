#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#include <IOKit/pci/IOPCIDevice.h>
#include <pexpert/pexpert.h>

class PhoenixProbe : public IOService {
    OSDeclareDefaultStructors(PhoenixProbe)

public:
    IOService *probe(IOService *provider, SInt32 *score) override;
    bool start(IOService *provider) override;
};

OSDefineMetaClassAndStructors(PhoenixProbe, IOService)

IOService *PhoenixProbe::probe(IOService *provider, SInt32 *score)
{
    int enabled = 0;
    IOPCIDevice *pci = OSDynamicCast(IOPCIDevice, provider);
    if (pci == nullptr || pci->configRead16(kIOPCIConfigVendorID) != 0x1002 ||
        !PE_parse_boot_argn("phoenixprobe", &enabled, sizeof(enabled)) || enabled != 1)
        return nullptr;

    return IOService::probe(provider, score);
}

bool PhoenixProbe::start(IOService *provider)
{
    IOPCIDevice *pci = OSDynamicCast(IOPCIDevice, provider);
    if (pci == nullptr || !IOService::start(provider))
        return false;

    IOLog("PhoenixProbe: AMD PCI %04x:%04x rev %02x at %02x:%02x.%x; diagnostic only, GPU left untouched\n",
          pci->configRead16(kIOPCIConfigVendorID), pci->configRead16(kIOPCIConfigDeviceID),
          pci->configRead8(kIOPCIConfigRevisionID), pci->getBusNumber(), pci->getDeviceNumber(),
          pci->getFunctionNumber());
    return true;
}

extern "C" {
kern_return_t _start(kmod_info_t *ki, void *data);
kern_return_t _stop(kmod_info_t *ki, void *data);
KMOD_EXPLICIT_DECL(com.raphaeli.PhoenixProbe, "0.1.0", _start, _stop)
__private_extern__ kmod_start_func_t *_realmain = nullptr;
__private_extern__ kmod_stop_func_t *_antimain = nullptr;
}
