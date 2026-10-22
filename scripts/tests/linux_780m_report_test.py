#!/usr/bin/env python3
"""Keep Linux 780M observations distinct from validated macOS support."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REPORT = (ROOT / "docs/reports/linux-780m-bringup.md").read_text()
INFO = (ROOT / "Raphaeli/Info.plist").read_text()

for evidence in (
    "1002:1900",
    "1002:15bf",
    "HawkPoint1",
    "gfx_v11_0_0",
    "GC 11.0.1 blobs",
    "active firmware",
    "does not establish macOS",
):
    assert evidence in REPORT, "Linux report missing evidence or caveat: " + evidence

# Linux GPU identification must not silently widen the conservative framebuffer match.
assert '<key>IOPCIPrimaryMatch</key><string>0x000015bf&amp;0xffffffff</string>' in INFO
assert "0x00001900&amp;0xffffffff" not in INFO

print("PASS: Linux HawkPoint evidence is recorded; no unverified 0x1900 match was added")
