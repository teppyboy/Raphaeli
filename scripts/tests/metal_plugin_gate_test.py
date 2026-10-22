"""Host gate for the Metal plugin layer (Task 6): the plugin stays unsupported until its contract exists.

Static checks only. Fails if any missing piece appears without the matching contract:
- the metal2vulkan runtime exports a C ABI (#[no_mangle]) or builds a cdylib/staticlib;
- an ObjC Metal plugin source (.m) exists under Raphaeli/Metal/;
- Info.plist registers a Metal plugin (MetalPluginName / MetalPluginClassName / IOGLBundleName);
- the C shim reports a device or backend;
- the blocked report does not name this gate and the exact missing layers.
It proves nothing about Metal or IOAccel runtime behavior.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RUNTIME = ROOT / "deps/metal2vulkan"
SHIM_DIR = ROOT / "Raphaeli/Metal"
PLIST = ROOT / "Raphaeli/Info.plist"
REPORT = ROOT / "docs/reports/metal-plugin.md"
GATE = "scripts/tests/metal_plugin_gate_test.py"

failures = []


def check(cond, what):
    if cond:
        print(f"ok    {what}")
    else:
        print(f"FAIL  {what}")
        failures.append(what)


def rust_sources():
    return [p for p in RUNTIME.rglob("*.rs") if "target" not in p.parts]


def cargo_manifests():
    return [p for p in RUNTIME.rglob("Cargo.toml") if "target" not in p.parts]


# Runtime: no supported C ABI. Any #[no_mangle] or extern "C" fn export would be a new entry point.
exports = [
    f"{p.relative_to(ROOT)}:{n}"
    for p in rust_sources()
    for n, line in enumerate(p.read_text(errors="replace").splitlines(), 1)
    if re.search(r"#\[no_mangle\]|#\[unsafe\(no_mangle\)\]", line)
]
check(not exports, f"runtime-no-c-abi-exports (found {exports})")

crate_types = [
    f"{p.relative_to(ROOT)}" for p in cargo_manifests()
    if re.search(r"crate-type\s*=\s*\[[^\]]*(cdylib|staticlib)", p.read_text(errors="replace"))
]
check(not crate_types, f"runtime-no-cdylib-staticlib (found {crate_types})")

# Plugin binding: no ObjC Metal plugin source.
objc = sorted(p.name for p in SHIM_DIR.glob("*.m")) if SHIM_DIR.is_dir() else []
check(not objc, f"metal-plugin-objc-absent (found {objc})")

# Registration: no Metal plugin keys anywhere in Info.plist, comments included, so the preflight can never read ready.
plist = PLIST.read_text(errors="replace")
keys = [k for k in ("MetalPluginName", "MetalPluginClassName", "IOGLBundleName") if k in plist]
check(not keys, f"plist-no-metal-plugin-keys (found {keys})")

# Shim: every entry point stays unsupported, and the shim never dlopens or names a backend.
shim_c = (SHIM_DIR / "nmx_metal_shim.c").read_text()
check("return NMX_METAL_UNSUPPORTED;" in shim_c and "return 0;" in shim_c,
      "shim-reports-unsupported")
check(not re.search(r"dlopen|dlsym|MTLCreateSystemDefaultDevice|vk[A-Z]\w*\(", shim_c),
      "shim-no-backend-calls")

# Report: must bind this gate and name every missing layer.
report = REPORT.read_text()
check(GATE in report and "Status: blocked" in report, "report-names-gate-and-status")
check(all(s in report for s in ("MetalPluginName", "#[no_mangle]", "cdylib")),
      "report-names-missing-symbols-and-registration")

if failures:
    print(f"metal plugin gate: {len(failures)} failed")
    sys.exit(1)
print("metal plugin gate: all passed")
