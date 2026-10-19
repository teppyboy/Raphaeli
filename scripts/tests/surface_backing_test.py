"""Check surface backing stays fail-closed until AMD GEM/TTM evidence exists."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UC = (ROOT / "Raphaeli/Kernel/nmx_accel_uc.cpp").read_text()
HEADER = (ROOT / "Raphaeli/Kernel/nmx_accel.h").read_text()

assert "AMD GEM/TTM surface backing contract is unverified" in UC
assert "no AMD GEM/TTM eviction mapping" in UC
assert "AMD surface layout is unverified" in UC
assert "surface backing REFUSED" in UC
assert "return false;" in UC[UC.index("bool RaphaeliVidMemory::allocPhysical()") :]
assert "nmx_accel_bridge_alloc(want" not in UC
assert "this + 0x40" not in UC
assert "this + 0xc8" not in UC
assert "pageoff(IOAccelEvent *, bool, bool *)" in HEADER
assert "set_shape_backing_length_ext" in HEADER
print("PASS: surface backing/page-off refuses without verified AMD GEM/TTM mapping")
