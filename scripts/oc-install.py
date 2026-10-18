#!/usr/bin/env python3
"""OpenCore integration for Raphaeli (Radeon 780M, Phoenix 0x15bf, gfx1103).

Portable core: Python3 stdlib only (plistlib, shutil, subprocess). Runs on
macOS and Linux.

For a Hackintosh whose ONLY GPU is the 780M: the kext is added to the OC
config but stays inert by default. xnu/nmx_kext.cpp probe() declines every
device unless the user opts in with the raphaeli-amd=1 boot-arg (or the
"raphaeli-gpu" device property), so a display-capable driver never loads
unintentionally and there is no half-attached GPU / black screen at boot.
-amdgpuoff parks every Raphaeli GPU driver for one boot; the NVRAM marker
raphaeli-gpu-attaching parks it after a failed attach (see install.sh).

OC injects kexts without an aux KC rebuild: this tool never touches
SystemKernelExtensions, /Library/KernelCollections or kmutil(8).

Usage:
  oc-install.py <mount-or-path-to-EFI-volume> [--add|--enable|--disable|--remove|--status]
                [--system-root <dir>] [--firmware-src <dir>] [--kext-src <dir>] [--dry-run]

  target        an already-mounted EFI volume path, or a disk identifier:
                macOS diskXsY (mounted via diskutil), Linux /dev/sdXN or bare
                sdXN (located via lsblk, mounted via udisksctl if available)
  --system-root system volume root for firmware staging (default /; second
                positional also accepted)
  --firmware-src dir with linux-firmware amdgpu blobs; stage via fw/stage.sh
                onto <system-root>/Library/Raphaeli/firmware
  --kext-src    single Raphaeli.kext bundle to copy (explicit override)
  --target      target macOS variant: sequoia or tahoe

Linux path (no macOS needed):
  python3 oc-install.py /media/user/EFI --add
  python3 oc-install.py /dev/sda1 --status --system-root /mnt/target

--add       backup config.plist, copy the selected kext into EFI/OC/Kexts/,
            insert or update a Kernel>Add entry. Adds NO
            boot-arg: the kext loads but stays inert until --enable.
--enable    append raphaeli-amd=1 to NVRAM>Add>7C43...:boot-args (idempotent)
--disable   strip raphaeli-amd=1 from boot-args (kext loads but parks)
--remove    delete the Kernel>Add entry and the Kexts/Raphaeli.kext copy
            (backups are kept)
--status    report kext presence, entry Enabled, boot-arg, staged firmware
--dry-run   print planned actions instead of running them
"""

import os
import plistlib
import re
import shutil
import subprocess
import sys
from datetime import datetime
from typing import Any, NamedTuple, NoReturn

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
# stage.sh lives next to us in the dist zip (tools/fw/stage.sh) or in the dev
# tree (Raphaeli/Firmware/stage.sh)
_FW_CANDIDATES = (
    os.path.join(SCRIPT_DIR, "fw", "stage.sh"),
    os.path.join(SCRIPT_DIR, "..", "Raphaeli", "Firmware", "stage.sh"),
)
FW_STAGE_SH = next((p for p in _FW_CANDIDATES if os.path.isfile(p)), _FW_CANDIDATES[0])
GUID = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
BOOT_ARG = "raphaeli-amd=1"
KEXT_NAME = "Raphaeli.kext"

DRY_RUN = False
VOL = ""
CONFIG = ""
KEXTS_DIR = ""
SYS_ROOT = "/"
SYSTEM_ROOT_SET = False
FW_SRC = ""
TARGET_SELECTOR = ""
KEXT_SRC_EXPLICIT = bool(os.environ.get("RAPHAELI_KEXT"))
# Optional source override. Target selection remains mandatory so every injected
# entry receives a real Darwin 24.x or 25.x kernel bound.
KEXT_SRC = os.environ.get("RAPHAELI_KEXT") or ""

class TargetInfo(NamedTuple):
    name: str
    source_bundle: str
    min_kernel: str
    max_kernel: str

TARGETS = {
    "sequoia": ("Sequoia", "24.0.0", "24.99.99"),
    "tahoe": ("Tahoe", "25.0.0", "25.99.99"),
}

def resolve_target(explicit: str, system_root: str, package_root: str) -> TargetInfo:
    selector = explicit.strip().lower()
    if selector:
        metadata = TARGETS.get(selector)
        if metadata is None:
            die(f"unsupported target {explicit!r}; use --target sequoia or --target tahoe")
    else:
        if not system_root:
            die("target is required: pass --target sequoia|tahoe or --system-root <mounted system volume>")
        version_path = os.path.join(system_root, "System", "Library", "CoreServices", "SystemVersion.plist")
        try:
            with open(version_path, "rb") as f:
                version = plistlib.load(f).get("ProductVersion", "")
        except (OSError, plistlib.InvalidFileException, ValueError) as e:
            die(f"cannot read ProductVersion from {version_path}: {e}")
        match = re.match(r"^(\d+)(?:\.|$)", version if isinstance(version, str) else "")
        major = int(match.group(1)) if match else -1
        if major == 15:
            selector = "sequoia"
        elif major == 26:
            selector = "tahoe"
        else:
            die(f"unsupported ProductVersion {version!r}; supported versions are 15.x (Sequoia) and 26.x (Tahoe)")
        metadata = TARGETS[selector]
    name, minimum, maximum = metadata
    source_candidates = (
        os.path.join(package_root, "target", name, KEXT_NAME),
        os.path.join(package_root, "out", "target", name, KEXT_NAME),
    )
    source = next((p for p in source_candidates if os.path.isdir(p)), source_candidates[0])
    return TargetInfo(name, os.path.normpath(source), minimum, maximum)


def die(msg: str) -> NoReturn:
    print(f"oc-install.py: {msg}", file=sys.stderr)
    sys.exit(1)


def log(msg: str) -> None:
    print(f"== {msg}")


def run(cmd: "list[str]") -> "subprocess.CompletedProcess[bytes] | None":
    """Planned external command runner: prints under --dry-run."""
    if DRY_RUN:
        print("DRY-RUN:", " ".join(cmd))
        return None
    return subprocess.run(cmd, check=False)


def usage() -> None:
    print((__doc__ or "").strip())


# ---- volume resolution -------------------------------------------------------

def resolve_volume_mac(t: str) -> str:
    if os.path.isdir(t):
        return t
    if re.fullmatch(r"disk\d+(s\d+)?", t) is None:
        die(f"not a directory or disk identifier: {t}")
    info = subprocess.run(["diskutil", "info", "-plist", t], capture_output=True)
    mp = ""
    if info.returncode == 0:
        try:
            loaded = plistlib.loads(info.stdout)
            val = loaded.get("MountPoint")
            if isinstance(val, (str, bytes)):
                mp = val.decode() if isinstance(val, bytes) else val
        except plistlib.InvalidFileException:
            pass
    if mp and "Not Mounted" not in mp and os.path.isdir(mp):
        return mp
    if DRY_RUN:
        die(f"dry-run: {t} is not mounted; mount it first (diskutil mount {t}) or pass its mount point")
    log(f"mounting EFI volume {t}")
    if subprocess.run(["diskutil", "mount", t], capture_output=True).returncode != 0:
        die(f"diskutil mount {t} failed")
    info = subprocess.run(["diskutil", "info", "-plist", t], capture_output=True)
    val: Any = None
    try:
        val = plistlib.loads(info.stdout)["MountPoint"]
    except (plistlib.InvalidFileException, KeyError):
        die(f"cannot determine mount point of {t}")
    return val.decode() if isinstance(val, bytes) else str(val)


def resolve_volume_linux(t: str) -> str:
    if os.path.isdir(t):
        return t
    dev = ""
    if t.startswith("/dev/"):
        dev = t
    elif re.fullmatch(r"[a-zA-Z0-9]+(\d+)?", t) and os.path.exists(f"/dev/{t}"):
        dev = f"/dev/{t}"
    if not dev:
        die(f"not a directory or block device: {t} "
            "(pass the mounted EFI path, e.g. /media/user/EFI, or a /dev/ partition)")
    out = subprocess.run(["lsblk", "-pno", "NAME,FSTYPE,PARTLABEL,MOUNTPOINT", dev],
                         capture_output=True, text=True)
    if out.returncode != 0:
        die(f"lsblk failed for {dev}")
    mp = ""
    for line in out.stdout.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 4 and parts[1] == "vfat":
            mp = parts[-1]
    if mp:
        return mp
    if DRY_RUN:
        die(f"dry-run: {dev} is not mounted; mount it first or pass its mount point")
    log(f"mounting EFI partition {dev} via udisksctl")
    r = subprocess.run(["udisksctl", "mount", "-b", dev], capture_output=True, text=True)
    m = re.search(r"at (/\S+)", r.stdout)
    if r.returncode != 0 or m is None:
        die(f"could not mount {dev} (udisksctl unavailable or failed). "
            f"Mount it manually, e.g.: sudo mount {dev} /mnt/efi && "
            f"python3 {os.path.abspath(__file__)} /mnt/efi --add")
    return m.group(1)


def resolve_volume(t: str) -> None:
    global VOL, CONFIG, KEXTS_DIR
    resolver = resolve_volume_mac if sys.platform == "darwin" else resolve_volume_linux
    VOL = resolver(t)
    cfg = os.path.join(VOL, "EFI", "OC", "config.plist")
    if not os.path.isfile(cfg):
        die(f"{VOL} does not look like an EFI volume (no EFI/OC/config.plist)")
    CONFIG = cfg
    KEXTS_DIR = os.path.join(VOL, "EFI", "OC", "Kexts")


# ---- config.plist helpers (plistlib) ------------------------------------------

def load_config() -> "dict":
    try:
        with open(CONFIG, "rb") as f:
            return plistlib.load(f)
    except (plistlib.InvalidFileException, OSError) as e:
        die(f"cannot parse {CONFIG}: {e}")


def save_config(cfg: "dict") -> None:
    tmp = CONFIG + ".raphaeli-tmp"
    try:
        with open(tmp, "wb") as f:
            plistlib.dump(cfg, f, fmt=plistlib.FMT_XML)
    except OSError as e:
        die(f"cannot write {tmp}: {e}")
    os.replace(tmp, CONFIG)


def validate_config() -> None:
    try:
        with open(CONFIG, "rb") as f:
            plistlib.load(f)
    except (plistlib.InvalidFileException, OSError) as e:
        die(f"config.plist invalid after edit ({e}); restore from backup")


def find_entry_indices(cfg: "dict") -> "list[int]":
    add = cfg.get("Kernel", {}).get("Add", [])
    if not isinstance(add, list):
        return []
    return [i for i, e in enumerate(add)
            if isinstance(e, dict) and e.get("BundlePath") == KEXT_NAME]


def find_entry_index(cfg: "dict") -> "int | None":
    indices = find_entry_indices(cfg)
    return indices[0] if indices else None


def read_bootargs(cfg: "dict") -> str:
    nv = cfg.get("NVRAM", {})
    add = nv.get("Add", {}) if isinstance(nv, dict) else {}
    guid = add.get(GUID, {}) if isinstance(add, dict) else {}
    val = guid.get("boot-args", "") if isinstance(guid, dict) else ""
    return val if isinstance(val, str) else ""


def has_boot_arg(cfg: "dict") -> bool:
    return BOOT_ARG in read_bootargs(cfg).split()


def strip_boot_arg(cfg: "dict") -> str:
    return " ".join(a for a in read_bootargs(cfg).split() if a != BOOT_ARG)


def set_bootargs(cfg: "dict", new: str) -> None:
    if "NVRAM" not in cfg or not isinstance(cfg["NVRAM"], dict):
        cfg["NVRAM"] = {}
    nv = cfg["NVRAM"]
    if not isinstance(nv.get("Add"), dict):
        nv["Add"] = {}
    add = nv["Add"]
    if GUID not in add or not isinstance(add[GUID], dict):
        add[GUID] = {}
    add[GUID]["boot-args"] = new


# ---- firmware census (names from fw/stage.sh, the source of truth) ------------

def fw_list(block: str) -> "list[str]":
    if not os.path.isfile(FW_STAGE_SH):
        die("fw/stage.sh not found next to oc-install.py")
    try:
        with open(FW_STAGE_SH) as f:
            text = f.read()
    except OSError as e:
        die(f"cannot read {FW_STAGE_SH}: {e}")
    m = re.search(rf'^{block}="\n(.*?)^\s*"\s*$', text, re.M | re.S)
    if m is None:
        die(f"cannot parse {block} list from fw/stage.sh")
    return [blob.strip() for blob in m.group(1).splitlines() if blob.strip()]


REQUIRED_FW = fw_list("REQUIRED")
OPTIONAL_FW = fw_list("OPTIONAL")


def firmware_status() -> None:
    fwroot = os.path.join(SYS_ROOT, "Library", "Raphaeli", "firmware", "amdgpu")
    print(f"firmware staged under {SYS_ROOT}/Library/Raphaeli/firmware (amdgpu/):")
    if not os.path.isdir(fwroot):
        print(f"  NOT STAGED (no {fwroot})")
        if FW_SRC:
            print(f"  source census in {FW_SRC}:")
            missing = 0
            for f in REQUIRED_FW:
                if os.path.isfile(os.path.join(FW_SRC, f)):
                    print(f"    present: {f}")
                else:
                    print(f"    MISSING: {f}")
                    missing += 1
            if missing:
                print(f"  source is incomplete: {missing} required blob(s) missing")
            else:
                print(f"  source census OK ({len(REQUIRED_FW)}/{len(REQUIRED_FW)})")
        return
    missing = present = 0
    for f in REQUIRED_FW:
        if os.path.isfile(os.path.join(fwroot, f)):
            present += 1
        else:
            print(f"  MISSING: amdgpu/{f}")
            missing += 1
    print(f"  required: {present}/{len(REQUIRED_FW)} present")
    for f in OPTIONAL_FW:
        if os.path.isfile(os.path.join(fwroot, f)):
            print(f"  optional present: amdgpu/{f}")
    if FW_SRC:
        srcmissing = sum(1 for f in REQUIRED_FW if not os.path.isfile(os.path.join(FW_SRC, f)))
        if srcmissing:
            print(f"  --firmware-src {FW_SRC} is incomplete: {srcmissing} required blob(s) missing")
        else:
            print(f"  --firmware-src {FW_SRC} census OK ({len(REQUIRED_FW)}/{len(REQUIRED_FW)})")


def stage_firmware() -> "tuple[str, str]":
    """Stage firmware privately, then publish it as one replaceable tree.

    The returned (root, old) pair remains a transaction until the caller calls
    finish_firmware(). A later config or kext failure can therefore restore the
    pre-existing firmware tree instead of leaving a partial install behind.
    """
    if not FW_SRC:
        return "", ""
    if not os.path.isdir(FW_SRC):
        die(f"--firmware-src not a directory: {FW_SRC}")
    missing = [f for f in REQUIRED_FW if not os.path.isfile(os.path.join(FW_SRC, f))]
    if missing:
        die(f"{len(missing)} required firmware blob(s) missing in {FW_SRC} (see fw/stage.sh)")
    fwroot = os.path.join(SYS_ROOT, "Library", "Raphaeli", "firmware")
    temporary = fwroot + ".raphaeli-staging"
    old = fwroot + ".raphaeli-old"
    log(f"staging firmware -> {fwroot}")
    if DRY_RUN:
        print("DRY-RUN: mkdir -p", fwroot)
        print("DRY-RUN: sh", FW_STAGE_SH, FW_SRC, fwroot)
        return "", ""
    if os.path.exists(temporary) or os.path.exists(old):
        die(f"firmware transaction paths already exist beside {fwroot}; remove them manually")
    moved_old = False
    try:
        # stage.sh may copy many blobs and fail part-way through. It only ever
        # sees the private tree, never the live firmware directory.
        r = subprocess.run(["sh", FW_STAGE_SH, FW_SRC, temporary])
        if r.returncode != 0:
            die("fw/stage.sh failed")
        if os.path.exists(fwroot):
            os.replace(fwroot, old)
            moved_old = True
        os.replace(temporary, fwroot)
    except BaseException:
        if os.path.exists(temporary):
            remove_path(temporary)
        if moved_old and not os.path.exists(fwroot) and os.path.exists(old):
            os.replace(old, fwroot)
        raise
    return fwroot, old if moved_old else ""

def finish_firmware(state: "tuple[str, str]") -> None:
    _root, old = state
    if old and os.path.exists(old):
        remove_path(old)

def rollback_firmware(state: "tuple[str, str]") -> None:
    root, old = state
    if not root:
        return
    if os.path.exists(root):
        remove_path(root)
    if old and os.path.exists(old):
        os.replace(old, root)


# ---- actions -------------------------------------------------------------------

def copy_kext(src: str, dst: str) -> None:
    # copytree preserves file+dir structure and works on both macOS and Linux
    if DRY_RUN:
        print("DRY-RUN: cp -a", src, dst)
        return
    if os.path.exists(dst):
        try:
            shutil.rmtree(dst)
        except OSError as e:
            die(f"cannot remove {dst}: {e}")
    shutil.copytree(src, dst, symlinks=True)


def stamp_target_metadata(bundle: str, target: TargetInfo) -> None:
    """Stamp selected target on the staged bundle, preserving bundle identity."""
    if not target.name:
        return
    info_path = os.path.join(bundle, "Contents", "Info.plist")
    try:
        with open(info_path, "rb") as stream:
            info = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException, ValueError) as e:
        die(f"cannot read staged kext metadata {info_path}: {e}")
    if not isinstance(info, dict):
        die(f"staged kext metadata is not a dictionary: {info_path}")
    info["SelectedTarget"] = target.name
    if info.get("CFBundleName") not in (None, "Raphaeli"):
        die(f"staged kext has unexpected CFBundleName: {info.get('CFBundleName')!r}")
    if "CFBundleName" not in info:
        info["CFBundleName"] = "Raphaeli"
    tmp = info_path + ".raphaeli-tmp"
    try:
        with open(tmp, "wb") as stream:
            plistlib.dump(info, stream, fmt=plistlib.FMT_XML)
        os.replace(tmp, info_path)
    except OSError as e:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        die(f"cannot stamp staged kext metadata {info_path}: {e}")


def remove_path(path: str) -> None:
    if os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path)
    else:
        os.unlink(path)

def prepare_staged_kext(source: str, staged: str, target: TargetInfo) -> str:
    """Build a sibling bundle before changing config.plist or staged output."""
    temporary = staged + ".raphaeli-staging"
    try:
        if os.path.exists(temporary):
            remove_path(temporary)
        copy_kext(source, temporary)
        stamp_target_metadata(temporary, target)
    except BaseException:
        try:
            if os.path.exists(temporary):
                remove_path(temporary)
        except OSError:
            pass
        raise
    return temporary

def commit_staged_kext(temporary: str, staged: str) -> str:
    """Replace staged bundle, retaining the old copy until config commit."""
    old = staged + ".raphaeli-old"
    moved_old = False
    try:
        if os.path.exists(old):
            remove_path(old)
        if os.path.exists(staged):
            os.replace(staged, old)
            moved_old = True
        os.replace(temporary, staged)
    except OSError:
        try:
            if os.path.exists(temporary):
                remove_path(temporary)
            if moved_old and not os.path.exists(staged):
                os.replace(old, staged)
        except OSError:
            pass
        raise
    return old if moved_old else ""

def finish_staged_kext(old: str) -> None:
    if old and os.path.exists(old):
        remove_path(old)

def restore_config_bytes(original: bytes) -> None:
    tmp = CONFIG + ".raphaeli-rollback"
    try:
        with open(tmp, "wb") as stream:
            stream.write(original)
        os.replace(tmp, CONFIG)
    except OSError as e:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        die(f"cannot roll back {CONFIG}: {e}")

def action_add() -> None:
    package_root = os.path.dirname(SCRIPT_DIR)
    target = resolve_target(TARGET_SELECTOR, SYS_ROOT if SYSTEM_ROOT_SET else "", package_root)
    source = KEXT_SRC if KEXT_SRC_EXPLICIT else target.source_bundle
    if not os.path.isdir(os.path.join(source, "Contents")):
        die(f"not a kext bundle: {source}")
    if not os.path.isfile(os.path.join(source, "Contents", "Info.plist")):
        die(f"kext bundle missing Contents/Info.plist: {source}")
    cfg = load_config()
    indices = find_entry_indices(cfg)
    idx = indices[0] if indices else None
    # Reject disabled existing entries before staging firmware or touching EFI.
    if idx is not None:
        enabled = cfg["Kernel"]["Add"][idx].get("Enabled")
        if enabled is not True:
            die(f"existing entry has Enabled={enabled}; fix config.plist manually")
    staged = os.path.join(KEXTS_DIR, KEXT_NAME)
    if DRY_RUN:
        if idx is not None:
            log(f"config entry already present at Kernel>Add:{idx}")
            print(f"DRY-RUN: refresh :Kernel>Add:{idx} for {target.name}")
        else:
            ts = datetime.now().strftime("%Y%m%d-%H%M%S")
            backup = f"{CONFIG}.raphaeli-backup-{ts}"
            print("DRY-RUN: cp", CONFIG, backup)
            print(f"DRY-RUN: append Raphaeli.kext to :Kernel:Add")
        copy_kext(source, staged)
        stage_firmware()
        return

    # Stage and stamp completely before touching config.plist. A failed copy or
    # metadata write must leave an existing entry and bundle byte-for-byte intact.
    with open(CONFIG, "rb") as stream:
        original_config = stream.read()
    temporary = prepare_staged_kext(source, staged, target)
    firmware_state = ("", "")
    try:
        firmware_state = stage_firmware()
    except BaseException:
        if os.path.exists(temporary):
            remove_path(temporary)
        raise

    # Keep a restorable original before mutating bounds, comments, duplicates,
    # or inserting a new entry. The backup is part of the install contract.
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = f"{CONFIG}.raphaeli-backup-{ts}"
    log(f"backing up config.plist -> {os.path.basename(backup)}")
    try:
        shutil.copy2(CONFIG, backup)
    except OSError as e:
        remove_path(temporary)
        rollback_firmware(firmware_state)
        die(f"cannot back up {CONFIG}: {e}")

    changed = False
    old = ""
    committed = False
    try:
        if idx is not None:
            log(f"config entry already present at Kernel>Add:{idx}")
            entry = cfg["Kernel"]["Add"][idx]
            if entry.get("Comment") != KEXT_NAME:
                log(f"refreshing Comment -> {KEXT_NAME!r}")
                entry["Comment"] = KEXT_NAME
                changed = True
            if entry.get("MinKernel") != target.min_kernel or entry.get("MaxKernel") != target.max_kernel:
                entry["MinKernel"] = target.min_kernel
                entry["MaxKernel"] = target.max_kernel
                changed = True
            if len(indices) > 1:
                log(f"removing {len(indices) - 1} duplicate Kernel>Add entries")
                for duplicate in reversed(indices[1:]):
                    cfg["Kernel"]["Add"].pop(duplicate)
                changed = True
        else:
            kernel = cfg.setdefault("Kernel", {})
            add = kernel.get("Add")
            if not isinstance(add, list):
                if add is not None:
                    remove_path(temporary)
                    die(":Kernel:Add exists but is not an array")
                log("creating missing Kernel>Add array")
                add = kernel["Add"] = []
            entry = {
                "Arch": "x86_64", "BundlePath": KEXT_NAME, "Comment": KEXT_NAME,
                "Enabled": True, "ExecutablePath": "Contents/MacOS/Raphaeli",
                "MaxKernel": target.max_kernel, "MinKernel": target.min_kernel,
                "PlistPath": "Contents/Info.plist",
            }
            log(f"inserting Kernel>Add:{len(add)} ({KEXT_NAME}, inert until {BOOT_ARG})")
            add.append(entry)
            changed = True

        old = commit_staged_kext(temporary, staged)
        committed = True
        if changed:
            save_config(cfg)
        finish_staged_kext(old)
    except BaseException:
        restore_config_bytes(original_config)
        if committed:
            if os.path.exists(staged):
                remove_path(staged)
            if old and os.path.exists(old):
                os.replace(old, staged)
        elif os.path.exists(temporary):
            remove_path(temporary)
        rollback_firmware(firmware_state)
        raise
    finish_firmware(firmware_state)
    validate_config()


def action_enable() -> None:
    cfg = load_config()
    if has_boot_arg(cfg):
        log(f"boot-args already contain {BOOT_ARG} (idempotent)")
        return
    cur = read_bootargs(cfg)
    new = f"{cur} {BOOT_ARG}".strip() if cur else BOOT_ARG
    log(f"boot-args -> {new!r}")
    if DRY_RUN:
        print(f"DRY-RUN: set :NVRAM:Add:{GUID}:boot-args = {new}")
    else:
        set_bootargs(cfg, new)
        save_config(cfg)


def action_disable() -> None:
    cfg = load_config()
    if not has_boot_arg(cfg):
        log(f"boot-args do not contain {BOOT_ARG} (nothing to do)")
        return
    new = strip_boot_arg(cfg)
    log("removed " + BOOT_ARG + " (kext still loads but parks itself = safe boot)")
    if DRY_RUN:
        print(f"DRY-RUN: set :NVRAM:Add:{GUID}:boot-args = {new!r}")
    else:
        set_bootargs(cfg, new)
        save_config(cfg)


def action_remove() -> None:
    cfg = load_config()
    indices = find_entry_indices(cfg)
    staged = os.path.join(KEXTS_DIR, KEXT_NAME)
    if indices:
        log(f"deleting {len(indices)} Kernel>Add entr{'y' if len(indices) == 1 else 'ies'} ({KEXT_NAME})")
    else:
        log(f"no Kernel>Add entry for {KEXT_NAME} (nothing to delete)")
    if DRY_RUN:
        if indices:
            print(f"DRY-RUN: delete :Kernel>Add entries {indices}")
        if os.path.exists(staged):
            print("DRY-RUN: rm -rf", staged)
        else:
            log(f"no EFI/OC/Kexts/{KEXT_NAME} staged")
        log("backups (config.plist.raphaeli-backup-*) are kept")
        return

    with open(CONFIG, "rb") as stream:
        original_config = stream.read()
    kext_backup = staged + ".raphaeli-remove"
    if os.path.exists(kext_backup):
        die(f"remove transaction path already exists: {kext_backup}")
    moved = False
    try:
        # Move the live bundle aside atomically before config commit. Keeping it
        # in the same directory makes the removal reversible without a partial
        # copy or delete.
        if os.path.exists(staged):
            os.replace(staged, kext_backup)
            moved = True
        else:
            log(f"no EFI/OC/Kexts/{KEXT_NAME} staged")
        if indices:
            for idx in reversed(indices):
                cfg["Kernel"]["Add"].pop(idx)
            save_config(cfg)
        if moved and os.path.exists(kext_backup):
            remove_path(kext_backup)
    except BaseException:
        try:
            restore_config_bytes(original_config)
            if moved and not os.path.exists(staged) and os.path.exists(kext_backup):
                os.replace(kext_backup, staged)
        except BaseException:
            raise
        finally:
            if os.path.exists(kext_backup):
                remove_path(kext_backup)
        raise
    log("backups (config.plist.raphaeli-backup-*) are kept")
    validate_config()


def status_target(cfg: "dict") -> "tuple[str, str, str]":
    """Return the selected target name and bounds without mutating the EFI."""
    package_root = os.path.dirname(SCRIPT_DIR)
    if TARGET_SELECTOR or SYSTEM_ROOT_SET:
        selected = resolve_target(
            TARGET_SELECTOR,
            SYS_ROOT if SYSTEM_ROOT_SET else "",
            package_root,
        )
        return selected.name, selected.min_kernel, selected.max_kernel

    idx = find_entry_index(cfg)
    if idx is not None:
        entry = cfg["Kernel"]["Add"][idx]
        minimum = entry.get("MinKernel", "")
        maximum = entry.get("MaxKernel", "")
        for name, target_min, target_max in TARGETS.values():
            if minimum == target_min and maximum == target_max:
                return name, target_min, target_max
        if isinstance(minimum, str) and isinstance(maximum, str):
            return "unknown", minimum, maximum
    return "unknown", "", ""

def action_status() -> None:
    cfg = load_config()
    idx = find_entry_index(cfg)
    target_name, min_kernel, max_kernel = status_target(cfg)
    print(f"EFI volume:        {VOL}")
    print(f"config.plist:      {CONFIG}")
    print(f"target:            {target_name}")
    if min_kernel or max_kernel:
        print(f"kernel bounds:     MinKernel={min_kernel}, MaxKernel={max_kernel}")
    else:
        print("kernel bounds:     not selected")
    if idx is not None:
        enabled = cfg["Kernel"]["Add"][idx].get("Enabled")
        print(f"config entry:      present at Kernel>Add:{idx}, Enabled={str(enabled).lower()}")
    else:
        print("config entry:      ABSENT (kext not injected)")
    if os.path.isdir(os.path.join(KEXTS_DIR, KEXT_NAME)):
        print(f"kext staged:       EFI/OC/Kexts/{KEXT_NAME}")
    else:
        print("kext staged:       NO")
    if has_boot_arg(cfg):
        print(f"boot-arg:          {BOOT_ARG} SET (GPU attachment enabled)")
    else:
        print("boot-arg:          not set (kext inert: probe() declines every device)")
    firmware_status()


SAFETY_NOTE = """
OC boot-menu safety:
  - Hold Cmd+V at the OC picker / boot for verbose output.
  - The kext is added Enabled=true but is INERT by default: nmx_kext.cpp probe()
    declines every device unless raphaeli-amd=1 is set (or the "raphaeli-gpu"
    device property). A display-capable driver never loads unintentionally.
  - To enable GPU attachment: --enable (adds raphaeli-amd=1 to boot-args).
  - To get your display back at any time: --disable (strips raphaeli-amd=1) or
    set Enabled=false on the Raphaeli.kext entry in config.plist, or boot with
    -amdgpuoff (parks every Raphaeli GPU driver for one boot).
  - Boot guard: the kext sets the NVRAM marker raphaeli-gpu-attaching while
    attaching; if a boot fails, the next boot parks the driver. Clear with:
    nvram -d raphaeli-gpu-attaching
  - OC injects kexts without an aux KC rebuild; SystemKernelExtensions and
    kmutil are never touched by this tool.
"""


def main(argv: "list[str]") -> int:
    global DRY_RUN, SYS_ROOT, SYSTEM_ROOT_SET, FW_SRC, KEXT_SRC
    global TARGET_SELECTOR, KEXT_SRC_EXPLICIT
    actions = {"--add": "add", "--enable": "enable", "--disable": "disable",
               "--remove": "remove", "--status": "status"}
    action = "status"
    target = ""
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in actions:
            action = actions[a]
        elif a == "--dry-run":
            DRY_RUN = True
        elif a in ("--firmware-src", "--system-root", "--kext-src", "--target"):
            if i + 1 >= len(argv):
                die(f"{a} needs an argument")
            val = argv[i + 1]
            i += 1
            if a == "--firmware-src":
                FW_SRC = val
            elif a == "--system-root":
                SYS_ROOT = val
                SYSTEM_ROOT_SET = True
            elif a == "--target":
                TARGET_SELECTOR = val
            else:
                KEXT_SRC = val
                KEXT_SRC_EXPLICIT = True
        elif a in ("-h", "--help"):
            usage()
            return 0
        elif a.startswith("-"):
            die(f"unknown option: {a} (see --help)")
        else:
            if not target:
                target = a
            elif SYS_ROOT == "/":
                SYS_ROOT = a
            else:
                die(f"unexpected argument: {a}")
        i += 1
    if not target:
        usage()
        die("missing target (mount point, path, or disk identifier)")
    resolve_volume(target)
    {"add": action_add, "enable": action_enable, "disable": action_disable,
     "remove": action_remove, "status": action_status}[action]()
    print(SAFETY_NOTE)
    log(f"done (action={action} dry-run={DRY_RUN})")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException) as e:
        print(f"oc-install.py: {e}", file=sys.stderr)
        sys.exit(1)
