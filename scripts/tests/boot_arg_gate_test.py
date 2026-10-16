"""Compile the production opt-in gate and verify its one-boot park argument."""
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / "Raphaeli/Kernel/nmx_kext.cpp").read_text()
start = source.index("static bool opted_in(")
opening = source.index("{", start)
depth = 1
end = opening + 1
while depth:
    depth += (source[end] == "{") - (source[end] == "}")
    end += 1
function = source[start:end]
assert "-amdgpuoff" in function

harness = r'''
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
struct OSObject { virtual ~OSObject() = default; };
struct OSBoolean : OSObject {
    bool value;
    bool isTrue() { return value; }
};
struct OSData : OSObject {
    uint8_t value;
    unsigned getLength() { return 1; }
    const void *getBytesNoCopy() { return &value; }
};
struct IOPCIDevice : OSObject {
    OSObject *property = nullptr;
    OSObject *getProperty(const char *) { return property; }
};
#define OSDynamicCast(type, object) dynamic_cast<type *>(object)
constexpr uint16_t AMD_VENDOR = 0x1002;
bool park, amd, intel;
const char *last_arg;
bool PE_parse_boot_argn(const char *name, int *value, unsigned size) {
    assert(size == sizeof(*value));
    last_arg = name;
    if (!std::strcmp(name, "-amdgpuoff")) return park;
    if (!std::strcmp(name, "raphaeli-amd")) { *value = amd; return amd; }
    if (!std::strcmp(name, "raphaeli-intel")) { *value = intel; return intel; }
    return false;
}
'''
harness += function
harness += r'''
int main() {
    IOPCIDevice pci;
    OSBoolean property;
    property.value = true;
    park = true;
    amd = true;
    assert(!opted_in(&pci, AMD_VENDOR));
    assert(!std::strcmp(last_arg, "-amdgpuoff"));

    park = false;
    assert(opted_in(&pci, AMD_VENDOR));
    assert(!std::strcmp(last_arg, "raphaeli-amd"));

    amd = false;
    pci.property = &property;
    assert(opted_in(&pci, AMD_VENDOR));
    puts("PASS: -amdgpuoff parks before vendor opt-in; renamed gate remains one-boot override");
}
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    (path / "boot_arg.cpp").write_text(harness)
    subprocess.run(["clang++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                    str(path / "boot_arg.cpp"), "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
