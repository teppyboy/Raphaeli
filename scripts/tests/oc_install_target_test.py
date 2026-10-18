#!/usr/bin/env python3
import importlib.util
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "oc-install.py"

spec = importlib.util.spec_from_file_location("oc_install", SCRIPT)
assert spec is not None and spec.loader is not None
oc_install = importlib.util.module_from_spec(spec)
spec.loader.exec_module(oc_install)


class TargetResolutionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.package = self.root / "package"
        self.efi = self.root / "efi"
        self._make_efi()
        self._make_kext(self.package / "target" / "Sequoia" / "Raphaeli.kext", "Sequoia")
        self._make_kext(self.package / "target" / "Tahoe" / "Raphaeli.kext", "Tahoe")

    def tearDown(self):
        self.tmp.cleanup()

    def _make_kext(self, path, selected_target=None):
        (path / "Contents" / "MacOS").mkdir(parents=True)
        metadata = {
            "CFBundleExecutable": "Raphaeli",
            "CFBundleName": "Raphaeli",
        }
        if selected_target is not None:
            metadata["SelectedTarget"] = selected_target
        (path / "Contents" / "Info.plist").write_bytes(plistlib.dumps(metadata))
        (path / "Contents" / "MacOS" / "Raphaeli").touch()

    def _make_efi(self):
        oc = self.efi / "EFI" / "OC"
        (oc / "Kexts").mkdir(parents=True)
        (oc / "config.plist").write_bytes(plistlib.dumps({"Kernel": {"Add": []}}))

    def _system_root(self, version):
        path = self.root / ("system-" + version)
        plist = path / "System" / "Library" / "CoreServices" / "SystemVersion.plist"
        plist.parent.mkdir(parents=True)
        plist.write_bytes(plistlib.dumps({"ProductVersion": version}))
        return path

    def _run_add(self, *args):
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(self.efi), "--add", *args],
            capture_output=True,
            text=True,
        )

    def _run_add_from_package(self, *args):
        package_script = self.package / "scripts" / "oc-install.py"
        package_script.parent.mkdir()
        shutil.copy2(SCRIPT, package_script)
        firmware_stage = self.package / "Raphaeli" / "Firmware" / "stage.sh"
        firmware_stage.parent.mkdir(parents=True)
        shutil.copy2(ROOT / "Raphaeli" / "Firmware" / "stage.sh", firmware_stage)
        return subprocess.run(
            [sys.executable, str(package_script), str(self.efi), "--add", *args],
            capture_output=True,
            text=True,
        )

    def _run_action(self, action, *args):
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(self.efi), action, *args],
            capture_output=True,
            text=True,
        )

    def test_explicit_targets_select_bundle_and_bounds(self):
        sequoia = oc_install.resolve_target("sequoia", "", str(self.package))
        self.assertEqual(sequoia.name, "Sequoia")
        self.assertEqual(sequoia.source_bundle, str(self.package / "target" / "Sequoia" / "Raphaeli.kext"))
        self.assertEqual((sequoia.min_kernel, sequoia.max_kernel), ("24.0.0", "24.99.99"))

        tahoe = oc_install.resolve_target("tahoe", "", str(self.package))
        self.assertEqual(tahoe.name, "Tahoe")
        self.assertEqual(tahoe.source_bundle, str(self.package / "target" / "Tahoe" / "Raphaeli.kext"))
        self.assertEqual((tahoe.min_kernel, tahoe.max_kernel), ("25.0.0", "25.99.99"))

    def test_system_root_product_version_selects_target(self):
        self.assertEqual(
            oc_install.resolve_target("", str(self._system_root("15.7")), str(self.package)).name,
            "Sequoia",
        )
        self.assertEqual(
            oc_install.resolve_target("", str(self._system_root("26.6")), str(self.package)).name,
            "Tahoe",
        )

    def test_missing_or_unsupported_target_fails_without_mutation(self):
        config = self.efi / "EFI" / "OC" / "config.plist"
        before = config.read_bytes()
        for args, expected in (((), "--target"), (("--system-root", str(self._system_root("14.0"))), "unsupported"), (("--system-root", str(self._system_root("27.0"))), "unsupported")):
            result = self._run_add(*args)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(expected, result.stderr)
            self.assertEqual(config.read_bytes(), before)
            self.assertFalse((self.efi / "EFI" / "OC" / "Kexts" / "Raphaeli.kext").exists())

    def test_add_uses_selected_bundle_and_bounds(self):
        result = self._run_add("--target", "tahoe", "--kext-src", str(self.package / "target" / "Tahoe" / "Raphaeli.kext"))
        self.assertEqual(result.returncode, 0, result.stderr)
        cfg = plistlib.loads((self.efi / "EFI" / "OC" / "config.plist").read_bytes())
        entry = cfg["Kernel"]["Add"][0]
        self.assertEqual(entry["MinKernel"], "25.0.0")
        self.assertEqual(entry["MaxKernel"], "25.99.99")
        self.assertTrue((self.efi / "EFI" / "OC" / "Kexts" / "Raphaeli.kext" / "Contents" / "Info.plist").is_file())

    def test_add_target_selects_bundle_without_kext_override(self):
        result = self._run_add_from_package("--target", "tahoe")
        self.assertEqual(result.returncode, 0, result.stderr)
        staged_info = plistlib.loads(
            (self.efi / "EFI" / "OC" / "Kexts" / "Raphaeli.kext" / "Contents" / "Info.plist").read_bytes()
        )
        self.assertEqual(staged_info["SelectedTarget"], "Tahoe")
        self.assertEqual(staged_info["CFBundleName"], "Raphaeli")

    def test_existing_entry_always_refreshes_selected_bounds(self):
        config = self.efi / "EFI" / "OC" / "config.plist"
        config.write_bytes(plistlib.dumps({"Kernel": {"Add": [{
            "BundlePath": "Raphaeli.kext",
            "Comment": "Raphaeli.kext",
            "Enabled": True,
            "MinKernel": "23.4.0",
            "MaxKernel": "23.99.99",
            "CustomField": "preserve-me",
        }]}}))
        result = self._run_add("--target", "tahoe", "--kext-src", str(self.package / "target" / "Tahoe" / "Raphaeli.kext"))
        self.assertEqual(result.returncode, 0, result.stderr)
        entry = plistlib.loads(config.read_bytes())["Kernel"]["Add"][0]
        self.assertEqual((entry["MinKernel"], entry["MaxKernel"]), ("25.0.0", "25.99.99"))
        self.assertEqual(entry["CustomField"], "preserve-me")

    def test_kext_override_requires_known_target_and_uses_override(self):
        override = self.root / "override" / "Raphaeli.kext"
        self._make_kext(override)
        result = self._run_add("--target", "sequoia", "--kext-src", str(override))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.efi / "EFI" / "OC" / "Kexts" / "Raphaeli.kext").is_dir())

    def test_status_reports_selected_target_and_bounds(self):
        result = self._run_add(
            "--target", "tahoe",
            "--kext-src", str(self.package / "target" / "Tahoe" / "Raphaeli.kext"),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self._run_action("--status", "--target", "tahoe")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("target:            Tahoe", result.stdout)
        self.assertIn("MinKernel=25.0.0, MaxKernel=25.99.99", result.stdout)

    def test_status_infers_target_from_existing_entry_bounds(self):
        config = self.efi / "EFI" / "OC" / "config.plist"
        config.write_bytes(plistlib.dumps({"Kernel": {"Add": [{
            "BundlePath": "Raphaeli.kext",
            "Enabled": True,
            "MinKernel": "24.0.0",
            "MaxKernel": "24.99.99",
        }]}}))
        result = self._run_action("--status")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("target:            Sequoia", result.stdout)

    def test_remove_deletes_only_staged_raphaeli_bundle(self):
        staged = self.efi / "EFI" / "OC" / "Kexts"
        self._make_kext(staged / "Raphaeli.kext")
        self._make_kext(staged / "Other.kext")
        config = self.efi / "EFI" / "OC" / "config.plist"
        config.write_bytes(plistlib.dumps({"Kernel": {"Add": [
            {"BundlePath": "Raphaeli.kext", "Enabled": True},
            {"BundlePath": "Other.kext", "Enabled": True},
        ]}}))
        result = self._run_action("--remove")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((staged / "Raphaeli.kext").exists())
        self.assertTrue((staged / "Other.kext").is_dir())
        entries = plistlib.loads(config.read_bytes())["Kernel"]["Add"]
        self.assertEqual([entry["BundlePath"] for entry in entries], ["Other.kext"])


if __name__ == "__main__":
    unittest.main()
