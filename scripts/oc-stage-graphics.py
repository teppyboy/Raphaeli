#!/usr/bin/env python3
"""Stage exact-build Apple graphics dependencies before Raphaeli for an OC test.

macOS host only. Defaults to validation/dry-run. Never installs Apple kexts on
system volumes. Runtime on the target remains unverified; keep the config backup.
"""
import argparse
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

FAMILIES = ("IOGraphicsFamily", "IOAcceleratorFamily2")
DIRECTORY = "RaphaeliDependencies"


def plist(path):
    with path.open("rb") as stream:
        return plistlib.load(stream)


def bundle(root, name):
    path = root / "System/Library/Extensions" / (name + ".kext")
    if (path / "Contents/Info.plist").is_file():
        path /= "Contents"
    info = plist(path / "Info.plist")
    executable = info["CFBundleExecutable"]
    binary = path / ("MacOS/" + executable if path.name == "Contents" else executable)
    if executable != name or not binary.is_file() or info["CFBundleIdentifier"] != "com.apple.iokit." + name:
        raise ValueError("Missing executable or incorrect bundle identity: " + name)
    return path, binary, info


def prepare(efi, recovery, kdk):
    efi, recovery, kdk = efi.resolve(), recovery.resolve(), kdk.resolve()
    config = efi / "EFI/OC/config.plist"
    cfg = plist(config)
    target_version = plist(recovery / "System/Library/CoreServices/SystemVersion.plist")
    kdk_version = plist(kdk / "System/Library/CoreServices/SystemVersion.plist")
    build = target_version["ProductBuildVersion"]
    if build != kdk_version["ProductBuildVersion"]:
        raise ValueError("Recovery/KDK build mismatch")
    # BaseSystem KC is essential evidence: never select dependency binaries by version alone.
    collection = subprocess.check_output([
        "kmutil", "inspect", "-B", str(recovery / "System/Library/KernelCollections/BootKernelExtensions.kc"),
        "-S", str(recovery / "System/Library/KernelCollections/BaseSystemKernelExtensions.kc"),
        "--show-kext-uuids", "--no-header"], text=True)
    add = cfg["Kernel"]["Add"]
    raphaeli = [i for i, entry in enumerate(add) if entry.get("BundlePath") == "Raphaeli.kext"]
    if len(raphaeli) != 1 or add[raphaeli[0]].get("Enabled") is not True:
        raise ValueError("Require exactly one enabled Raphaeli.kext entry")
    destination = efi / "EFI/OC/Kexts" / DIRECTORY
    if destination.exists() or destination.is_symlink():
        raise ValueError("Dependency staging directory already exists: " + str(destination))
    for entry in add + cfg["Kernel"].get("Force", []):
        path = entry.get("BundlePath", "").replace("\\", "/")
        if DIRECTORY in path.split("/") or path.split("/")[-1] in [n + ".kext" for n in FAMILIES]:
            raise ValueError("Existing graphics dependency entry; inspect manually: " + path)
    entries, sources = [], []
    # Restrict this experimental dependency set to the exact Darwin minor under test.
    match = re.search(r"Darwin Kernel Version (\d+)\.(\d+)\.", subprocess.check_output(
        ["strings", str(kdk / "System/Library/Kernels/kernel")], text=True))
    if not match:
        raise ValueError("Cannot determine KDK Darwin version")
    minimum = ".".join(match.groups()) + ".0"
    maximum = ".".join(match.groups()) + ".99"
    for name in FAMILIES:
        path, binary, info = bundle(kdk, name)
        uuid_text = subprocess.check_output(["dwarfdump", "--uuid", str(binary)], text=True)
        uuid = re.search(r"UUID: ([0-9A-Fa-f-]+) \(x86_64\)", uuid_text)
        identifier = info["CFBundleIdentifier"]
        lines = [line for line in collection.splitlines() if line.split() and line.split()[0] == identifier]
        if not uuid or len(lines) != 1 or "(" + uuid.group(1).upper() + ")" not in lines[0].upper():
            raise ValueError("Recovery KC/KDK x86_64 UUID mismatch: " + name)
        fields = lines[0].split()
        if len(fields) < 2 or fields[1] != info["CFBundleVersion"]:
            raise ValueError("Recovery KC/KDK version mismatch: " + name)
        print(name + ": matching UUID " + uuid.group(1) + ", build " + build)
        sources.append((name, path / "Info.plist", binary))
        entries.append({"Arch": "x86_64", "BundlePath": DIRECTORY + "/" + name + ".kext",
                        "Comment": "Raphaeli dependency test " + build, "Enabled": True,
                        "ExecutablePath": "Contents/MacOS/" + info["CFBundleExecutable"],
                        "PlistPath": "Contents/Info.plist", "MinKernel": minimum, "MaxKernel": maximum})
    add[raphaeli[0]:raphaeli[0]] = entries
    return config, cfg, destination, sources


def apply(config, cfg, destination, sources):
    # Validate everything before copying. Preserve original config before the only atomic config write.
    fd, backup = tempfile.mkstemp(prefix="config.plist.raphaeli-graphics-backup-", dir=str(config.parent))
    os.close(fd)
    shutil.copy2(config, backup)
    stage = Path(tempfile.mkdtemp(prefix=".raphaeli-graphics-", dir=str(destination.parent)))
    tmp = None
    staged = False
    try:
        for name, info, binary in sources:
            contents = stage / (name + ".kext") / "Contents"
            (contents / "MacOS").mkdir(parents=True)
            shutil.copy2(info, contents / "Info.plist")
            shutil.copy2(binary, contents / "MacOS" / binary.name)
        # mkdir refuses overwrite even if another process stages files after validation.
        destination.mkdir()
        staged = True
        for path in stage.iterdir():
            shutil.move(str(path), str(destination / path.name))
        fd, tmp = tempfile.mkstemp(prefix=".config-raphaeli-", dir=str(config.parent))
        with os.fdopen(fd, "wb") as stream:
            plistlib.dump(cfg, stream)
        shutil.copymode(config, tmp)
        os.replace(tmp, config)
        tmp = None
    except Exception:
        if staged:
            shutil.rmtree(destination)
        raise
    finally:
        shutil.rmtree(stage)
        if tmp is not None:
            Path(tmp).unlink()
    print("Config backup: " + backup)
    print("Rollback: restore that backup, then remove " + str(destination))
    print("After any OS/Recovery update, restore the backup and revalidate dependencies before booting.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("efi", type=Path, help="Mounted EFI root containing EFI/OC")
    parser.add_argument("recovery", type=Path, help="Mounted read-only BaseSystem.dmg root")
    parser.add_argument("kdk", type=Path, help="Matching KDK root (or extracted package Payload)")
    parser.add_argument("--apply", action="store_true", help="Stage files and update backed-up OC config")
    args = parser.parse_args()
    try:
        config, cfg, destination, sources = prepare(args.efi, args.recovery, args.kdk)
        print("Experimental: injection-tested only; target runtime/duplicate-KC behavior unverified.")
        if args.apply:
            apply(config, cfg, destination, sources)
        else:
            print("Dry-run: would stage into " + str(destination) + " before Raphaeli; no changes made.")
    except (OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException, subprocess.CalledProcessError) as exc:
        parser.exit(1, str(exc) + "\n")


if __name__ == "__main__":
    main()
