#!/bin/bash
# Thin wrapper around oc-install.py (the portable, Python3-stdlib core).
# Requires python3: present on macOS with Xcode/CLT (/usr/bin/python3) and on
# virtually every Linux distro. No macOS-only commands are needed for config
#.plist work; volume mounting falls back to diskutil (macOS) or lsblk +
# udisksctl (Linux); pass a mounted EFI path on Linux if udisksctl is absent.
#
# Usage (identical to the python core):
#   oc-install.sh <mount-or-path-to-EFI-volume> [--add|--enable|--disable|--remove|--status]
#                 [--system-root <dir>] [--firmware-src <dir>] [--kext-src <dir>] [--dry-run]
#
# Linux path (no macOS needed):
#   python3 oc-install.py /media/user/EFI --add
#   oc-install.sh /media/user/EFI --status --system-root /mnt/target
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PY=$(command -v python3 || command -v python || true)
if [[ -z $PY ]]; then
  echo "oc-install.sh: python3 is required (macOS: install Xcode Command Line Tools; Linux: install python3)" >&2
  exit 1
fi

exec "$PY" "$SCRIPT_DIR/oc-install.py" "$@"
