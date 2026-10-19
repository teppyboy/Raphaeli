"""Host fixtures only: no mounted EFI or system modifications."""
import importlib.util
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "stage_graphics", Path(__file__).resolve().parents[1] / "oc-stage-graphics.py")
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
UUID = "B77A42EC-6B0C-3A8D-89A2-B8F4CDBAC8C9"


class StageGraphicsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.efi = self.root / "EFI volume"
        self.recovery = self.root / "Recovery"
        self.kdk = self.root / "KDK"
        self.config = self.efi / "EFI/OC/config.plist"
        self.config.parent.joinpath("Kexts/Raphaeli.kext/Contents/MacOS").mkdir(parents=True)
        (self.config.parent / "Kexts/Raphaeli.kext/Contents/MacOS/Raphaeli").write_bytes(b"fixture Raphaeli")
        self.original = {"Kernel": {"Add": [
            {"BundlePath": "Lilu.kext", "Enabled": True},
            {"BundlePath": "Raphaeli.kext", "Enabled": True}], "Force": []},
            "NVRAM": {"untouched": "value"}}
        self.save(self.config, self.original)
        for root in (self.recovery, self.kdk):
            self.save(root / "System/Library/CoreServices/SystemVersion.plist",
                      {"ProductBuildVersion": "25G83"})
        for index, name in enumerate(MODULE.FAMILIES):
            # Exercise both flat IOGraphicsFamily and Contents IOAccelerator bundles.
            bundle = self.kdk / "System/Library/Extensions" / (name + ".kext")
            if index:
                bundle /= "Contents"
            self.save(bundle / "Info.plist", {"CFBundleIdentifier": "com.apple.iokit." + name,
                                             "CFBundleExecutable": name, "CFBundleVersion": "1"})
            binary = bundle / ("MacOS/" + name if index else name)
            binary.parent.mkdir(exist_ok=True)
            binary.write_bytes(b"fixture binary")
        self.mock = patch.object(MODULE.subprocess, "check_output", side_effect=self.command)
        self.mock.start()
        self.addCleanup(self.mock.stop)

    def save(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps(value))

    def command(self, args, **kwargs):
        if args[0] == "kmutil":
            return "\n".join("com.apple.iokit." + name + " 1 path (" + UUID + ")"
                             for name in MODULE.FAMILIES)
        if args[0] == "dwarfdump":
            return "UUID: " + UUID + " (x86_64) binary\n"
        if args[0] == "strings":
            return "Darwin Kernel Version 25.6.0: fixture"
        raise AssertionError(args)

    def prepare(self):
        return MODULE.prepare(self.efi, self.recovery, self.kdk)

    def test_dry_run_and_apply(self):
        before = self.config.read_bytes()
        config, cfg, dest, sources = self.prepare()
        self.assertEqual(self.config.read_bytes(), before)
        self.assertFalse(dest.exists())
        MODULE.apply(config, cfg, dest, sources)
        result = plistlib.loads(self.config.read_bytes())
        entries = result["Kernel"]["Add"]
        self.assertEqual([entry["BundlePath"] for entry in entries], [
            "Lilu.kext", "Raphaeli.kext/Contents/PlugIns/IOGraphicsFamily.kext",
            "Raphaeli.kext/Contents/PlugIns/IOAcceleratorFamily2.kext", "Raphaeli.kext"])
        self.assertEqual(result["NVRAM"], self.original["NVRAM"])
        self.assertEqual(entries[1]["MinKernel"], "25.6.0")
        self.assertEqual(entries[1]["MaxKernel"], "25.6.99")
        backups = list(config.parent.glob("config.plist.raphaeli-graphics-backup-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), before)
        self.assertFalse((self.efi / "EFI/OC/Kexts/RaphaeliDependencies").exists())
        for name in MODULE.FAMILIES:
            self.assertTrue((dest / (name + ".kext/Contents/MacOS/" + name)).is_file())
        with self.assertRaises(ValueError):
            self.prepare()

    def test_build_mismatch(self):
        self.save(self.kdk / "System/Library/CoreServices/SystemVersion.plist",
                  {"ProductBuildVersion": "25G72"})
        with self.assertRaisesRegex(ValueError, "build mismatch"):
            self.prepare()

    def test_uuid_mismatch(self):
        with patch.object(MODULE.subprocess, "check_output", side_effect=lambda args, **kw:
                          "UUID: 0000 (x86_64)" if args[0] == "dwarfdump" else self.command(args)), \
                self.assertRaisesRegex(ValueError, "UUID mismatch"):
            self.prepare()

    def test_version_mismatch(self):
        path = self.kdk / "System/Library/Extensions/IOGraphicsFamily.kext/Info.plist"
        info = MODULE.plist(path)
        info["CFBundleVersion"] = "2"
        self.save(path, info)
        with self.assertRaisesRegex(ValueError, "version mismatch"):
            self.prepare()

    def test_disabled_raphaeli(self):
        self.original["Kernel"]["Add"][1]["Enabled"] = False
        self.save(self.config, self.original)
        with self.assertRaisesRegex(ValueError, "enabled Raphaeli"):
            self.prepare()

    def test_existing_force_dependency(self):
        self.original["Kernel"]["Force"] = [{"BundlePath":
            "System\\Library\\Extensions\\IOGraphicsFamily.kext"}]
        self.save(self.config, self.original)
        with self.assertRaisesRegex(ValueError, "Existing graphics"):
            self.prepare()

    def test_failed_copy_leaves_config_unchanged(self):
        before = self.config.read_bytes()
        config, cfg, dest, sources = self.prepare()
        with patch.object(MODULE.shutil, "copy2", side_effect=[None, OSError("disk full")]), \
                self.assertRaises(OSError):
            MODULE.apply(config, cfg, dest, sources)
        self.assertFalse(dest.exists())
        self.assertEqual(self.config.read_bytes(), before)

    def test_config_write_failure_rolls_back_dependency_directory(self):
        before = self.config.read_bytes()
        config, cfg, dest, sources = self.prepare()
        with patch.object(MODULE.os, "replace", side_effect=OSError("cannot replace")), \
                self.assertRaises(OSError):
            MODULE.apply(config, cfg, dest, sources)
        self.assertFalse(dest.exists())
        self.assertEqual(self.config.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
