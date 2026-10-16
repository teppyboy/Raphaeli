"""Compile the real BAR helper and the actual start() prefix through the PCI gates."""
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / "Raphaeli/Kernel/nmx_pci.cpp").read_text()
start = source.index('extern "C" int nmx_xnu_pci_bar_info(')
end = source.index("\n}", start) + 2
helper = source[start:end]
source = (ROOT / "Raphaeli/Kernel/nmx_kext.cpp").read_text()
start = source.index("bool Raphaeli::start(IOService *provider)")
end = source.index('    IOLog("Raphaeli checkpoint: PCI checks passed;', start)
gate = source[start:end] + "    return true;\n}\n"
harness = r'''
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstdarg>
#include <cstring>
using UInt8 = unsigned char;
constexpr int kIOPCIConfigBaseAddress0 = 0x10;
#define OSDynamicCast(type, obj) static_cast<type *>(obj)
int stopped, interrupt_count = 1;
void *g_lock = reinterpret_cast<void *>(1);
char last_log[256];
void IOLog(const char *format, ...) {
    va_list args; va_start(args, format);
    vsnprintf(last_log, sizeof(last_log), format, args); va_end(args);
}
struct IOService {
    bool start(IOService *) { return true; }
    void stop(IOService *) { ++stopped; }
};
struct IODeviceMemory {
    uint64_t bytes = 4096;
    uint64_t getPhysicalAddress() { return 0x100000; }
    uint64_t getLength() { return bytes; }
} memory;
struct IOPCIDevice : IOService {
    IODeviceMemory *mem = &memory;
    unsigned bar = 0;
    IODeviceMemory *getDeviceMemoryWithRegister(UInt8) { return mem; }
    unsigned configRead32(UInt8) { return bar; }
};
int nmx_xnu_pci_msi_count(void *) { return interrupt_count; }
struct Raphaeli : IOService { bool start(IOService *provider); };
'''
harness += helper + gate
harness += r'''
int main() {
    Raphaeli driver;
    IOPCIDevice pci;
    assert(driver.start(&pci));
    assert(stopped == 0);
    pci.mem = nullptr;
    assert(!driver.start(&pci));
    assert(strstr(last_log, "size 0, io 0"));
    pci.mem = &memory;
    memory.bytes = 0;
    assert(!driver.start(&pci));
    memory.bytes = 4096;
    pci.bar = 1;
    assert(!driver.start(&pci));
    pci.bar = 0;
    interrupt_count = 0;
    assert(!driver.start(&pci));
    assert(stopped == 4);
    assert(!driver.start(nullptr));
    interrupt_count = 1;
    g_lock = nullptr;
    assert(!driver.start(&pci));
    puts("PASS: real BAR helper/start prefix accepts valid MMIO, rejects absent/empty/IO BAR and missing MSI");
}
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    (path / "gate.cpp").write_text(harness)
    subprocess.run(["clang++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                    str(path / "gate.cpp"), "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
