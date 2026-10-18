#!/usr/bin/env python3
import importlib.util
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import call, patch


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
        self._make_kext(self.package / "target" / "Sequoia" / "Raphaeli.kext")
        self._make_kext(self.package / "target" / "Tahoe" / "Raphaeli.kext")

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

    def test_add_stamps_selected_target_metadata_in_production(self):
        result = self._run_add_from_package("--target", "tahoe")
        self.assertEqual(result.returncode, 0, result.stderr)
        staged_info = plistlib.loads(
            (self.efi / "EFI" / "OC" / "Kexts" / "Raphaeli.kext" / "Contents" / "Info.plist").read_bytes()
        )
        self.assertEqual(staged_info["SelectedTarget"], "Tahoe")
        self.assertEqual(staged_info["CFBundleName"], "Raphaeli")
        source_info = plistlib.loads(
            (self.package / "target" / "Tahoe" / "Raphaeli.kext" / "Contents" / "Info.plist").read_bytes()
        )
        self.assertNotIn("SelectedTarget", source_info)

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
        backups = list(config.parent.glob("config.plist.raphaeli-backup-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), plistlib.dumps({"Kernel": {"Add": [{
            "BundlePath": "Raphaeli.kext", "Comment": "Raphaeli.kext", "Enabled": True,
            "MinKernel": "23.4.0", "MaxKernel": "23.99.99", "CustomField": "preserve-me",
        }]}}))

    def test_disabled_existing_entry_rejected_before_firmware_staging(self):
        config = self.efi / "EFI" / "OC" / "config.plist"
        config.write_bytes(plistlib.dumps({"Kernel": {"Add": [{
            "BundlePath": "Raphaeli.kext", "Enabled": False,
        }]}}))
        old_stage = oc_install.stage_firmware
        old_values = (oc_install.CONFIG, oc_install.KEXTS_DIR, oc_install.KEXT_SRC,
                      oc_install.KEXT_SRC_EXPLICIT, oc_install.TARGET_SELECTOR,
                      oc_install.SYSTEM_ROOT_SET, oc_install.DRY_RUN)
        try:
            oc_install.CONFIG = str(config)
            oc_install.KEXTS_DIR = str(self.efi / "EFI" / "OC" / "Kexts")
            oc_install.KEXT_SRC = str(self.package / "target" / "Tahoe" / "Raphaeli.kext")
            oc_install.KEXT_SRC_EXPLICIT = True
            oc_install.TARGET_SELECTOR = "tahoe"
            oc_install.SYSTEM_ROOT_SET = False
            oc_install.DRY_RUN = False
            def unexpected_firmware_stage():
                raise AssertionError("firmware staging must not run for disabled entry")
            oc_install.stage_firmware = unexpected_firmware_stage
            with self.assertRaises(SystemExit):
                oc_install.action_add()
        finally:
            oc_install.stage_firmware = old_stage
            (oc_install.CONFIG, oc_install.KEXTS_DIR, oc_install.KEXT_SRC,
             oc_install.KEXT_SRC_EXPLICIT, oc_install.TARGET_SELECTOR,
             oc_install.SYSTEM_ROOT_SET, oc_install.DRY_RUN) = old_values
        self.assertEqual(config.read_bytes(), plistlib.dumps({"Kernel": {"Add": [{
            "BundlePath": "Raphaeli.kext", "Enabled": False,
        }]}}))
        self.assertFalse((self.efi / "EFI" / "OC" / "Kexts" / "Raphaeli.kext").exists())

    def test_existing_entry_copy_failure_preserves_config_and_staged_bundle(self):
        config = self.efi / "EFI" / "OC" / "config.plist"
        config.write_bytes(plistlib.dumps({"Kernel": {"Add": [{
            "BundlePath": "Raphaeli.kext", "Comment": "old", "Enabled": True,
            "MinKernel": "23.4.0", "MaxKernel": "23.99.99",
        }]}}))
        staged = self.efi / "EFI" / "OC" / "Kexts" / "Raphaeli.kext"
        self._make_kext(staged, selected_target="Sequoia")
        config_before = config.read_bytes()
        staged_before = {p.relative_to(staged): p.read_bytes() for p in staged.rglob("*") if p.is_file()}
        old_copy_kext = oc_install.copy_kext
        old_values = (oc_install.CONFIG, oc_install.KEXTS_DIR, oc_install.KEXT_SRC,
                      oc_install.KEXT_SRC_EXPLICIT, oc_install.TARGET_SELECTOR,
                      oc_install.SYSTEM_ROOT_SET, oc_install.DRY_RUN)
        try:
            oc_install.CONFIG = str(config)
            oc_install.KEXTS_DIR = str(staged.parent)
            oc_install.KEXT_SRC = str(self.package / "target" / "Tahoe" / "Raphaeli.kext")
            oc_install.KEXT_SRC_EXPLICIT = True
            oc_install.TARGET_SELECTOR = "tahoe"
            oc_install.SYSTEM_ROOT_SET = False
            oc_install.DRY_RUN = False
            def fail_copy(_source, _destination):
                raise OSError("simulated staging failure")
            oc_install.copy_kext = fail_copy
            with self.assertRaises(OSError):
                oc_install.action_add()
        finally:
            oc_install.copy_kext = old_copy_kext
            (oc_install.CONFIG, oc_install.KEXTS_DIR, oc_install.KEXT_SRC,
             oc_install.KEXT_SRC_EXPLICIT, oc_install.TARGET_SELECTOR,
             oc_install.SYSTEM_ROOT_SET, oc_install.DRY_RUN) = old_values
        self.assertEqual(config.read_bytes(), config_before)
        self.assertEqual(
            {p.relative_to(staged): p.read_bytes() for p in staged.rglob("*") if p.is_file()},
            staged_before,
        )
        self.assertFalse((staged.parent / "Raphaeli.kext.raphaeli-staging").exists())

    def test_firmware_stage_failure_leaves_no_partial_install(self):
        config = self.efi / "EFI" / "OC" / "config.plist"
        before = config.read_bytes()
        source = self.root / "firmware-source"
        source.mkdir()
        for name in oc_install.REQUIRED_FW:
            (source / name).write_bytes(b"firmware")
        stage = self.root / "stage-fails.sh"
        stage.write_text("#!/bin/sh\nmkdir -p \\\"$2/amdgpu\\\"\ncp \\\"$1/" + oc_install.REQUIRED_FW[0] + "\\\" \\\"$2/amdgpu/\\\"\nexit 1\n")
        stage.chmod(0o755)
        old_values = (oc_install.CONFIG, oc_install.KEXTS_DIR, oc_install.KEXT_SRC,
                      oc_install.KEXT_SRC_EXPLICIT, oc_install.TARGET_SELECTOR,
                      oc_install.SYSTEM_ROOT_SET, oc_install.SYS_ROOT, oc_install.FW_SRC,
                      oc_install.FW_STAGE_SH, oc_install.DRY_RUN)
        try:
            oc_install.CONFIG = str(config)
            oc_install.KEXTS_DIR = str(self.efi / "EFI/OC/Kexts")
            oc_install.KEXT_SRC = str(self.package / "target/Tahoe/Raphaeli.kext")
            oc_install.KEXT_SRC_EXPLICIT = True
            oc_install.TARGET_SELECTOR = "tahoe"
            oc_install.SYSTEM_ROOT_SET = False
            oc_install.SYS_ROOT = str(self.root / "system")
            oc_install.FW_SRC = str(source)
            oc_install.FW_STAGE_SH = str(stage)
            oc_install.DRY_RUN = False
            with self.assertRaises(SystemExit):
                oc_install.action_add()
        finally:
            (oc_install.CONFIG, oc_install.KEXTS_DIR, oc_install.KEXT_SRC,
             oc_install.KEXT_SRC_EXPLICIT, oc_install.TARGET_SELECTOR,
             oc_install.SYSTEM_ROOT_SET, oc_install.SYS_ROOT, oc_install.FW_SRC,
             oc_install.FW_STAGE_SH, oc_install.DRY_RUN) = old_values
        self.assertEqual(config.read_bytes(), before)
        self.assertFalse((self.efi / "EFI/OC/Kexts/Raphaeli.kext").exists())
        self.assertFalse((self.root / "system/Library/Raphaeli/firmware").exists())
        self.assertFalse((self.root / "system/Library/Raphaeli/firmware.raphaeli-staging").exists())

    def test_config_commit_failure_rolls_back_firmware_and_kext(self):
        config = self.efi / "EFI/OC/config.plist"
        before = config.read_bytes()
        source = self.root / "firmware-source"
        source.mkdir()
        for name in oc_install.REQUIRED_FW:
            (source / name).write_bytes(b"firmware")
        old_values = (oc_install.CONFIG, oc_install.KEXTS_DIR, oc_install.KEXT_SRC,
                      oc_install.KEXT_SRC_EXPLICIT, oc_install.TARGET_SELECTOR,
                      oc_install.SYSTEM_ROOT_SET, oc_install.SYS_ROOT, oc_install.FW_SRC,
                      oc_install.FW_STAGE_SH, oc_install.DRY_RUN)
        try:
            oc_install.CONFIG = str(config)
            oc_install.KEXTS_DIR = str(self.efi / "EFI/OC/Kexts")
            oc_install.KEXT_SRC = str(self.package / "target/Tahoe/Raphaeli.kext")
            oc_install.KEXT_SRC_EXPLICIT = True
            oc_install.TARGET_SELECTOR = "tahoe"
            oc_install.SYSTEM_ROOT_SET = False
            oc_install.SYS_ROOT = str(self.root / "system")
            oc_install.FW_SRC = str(source)
            oc_install.FW_STAGE_SH = str(ROOT / "Raphaeli/Firmware/stage.sh")
            oc_install.DRY_RUN = False
            with patch.object(oc_install, "save_config", side_effect=OSError("simulated config failure")), \
                    self.assertRaises(OSError):
                oc_install.action_add()
        finally:
            (oc_install.CONFIG, oc_install.KEXTS_DIR, oc_install.KEXT_SRC,
             oc_install.KEXT_SRC_EXPLICIT, oc_install.TARGET_SELECTOR,
             oc_install.SYSTEM_ROOT_SET, oc_install.SYS_ROOT, oc_install.FW_SRC,
             oc_install.FW_STAGE_SH, oc_install.DRY_RUN) = old_values
        self.assertEqual(config.read_bytes(), before)
        self.assertFalse((self.efi / "EFI/OC/Kexts/Raphaeli.kext").exists())
        firmware_root = self.root / "system/Library/Raphaeli/firmware"
        self.assertFalse(firmware_root.exists())
        self.assertFalse((self.root / "system/Library/Raphaeli/firmware.raphaeli-staging").exists())

    def test_remove_rename_failure_preserves_config_and_staged_kext(self):
        config = self.efi / "EFI/OC/config.plist"
        config.write_bytes(plistlib.dumps({"Kernel": {"Add": [
            {"BundlePath": "Raphaeli.kext", "Enabled": True}]}}))
        staged = self.efi / "EFI/OC/Kexts/Raphaeli.kext"
        self._make_kext(staged)
        backup = staged.parent / "Raphaeli.kext.raphaeli-remove"
        before = config.read_bytes()
        staged_before = {p.relative_to(staged): p.read_bytes() for p in staged.rglob("*") if p.is_file()}
        old_values = (oc_install.CONFIG, oc_install.KEXTS_DIR, oc_install.DRY_RUN)
        try:
            oc_install.CONFIG = str(config)
            oc_install.KEXTS_DIR = str(staged.parent)
            oc_install.DRY_RUN = False
            real_replace = oc_install.os.replace
            def fail_staged(source, destination):
                if source == str(staged) and destination == str(backup):
                    raise OSError("simulated rename failure")
                return real_replace(source, destination)
            with patch.object(oc_install.os, "replace", side_effect=fail_staged), \
                    self.assertRaises(OSError):
                oc_install.action_remove()
        finally:
            (oc_install.CONFIG, oc_install.KEXTS_DIR, oc_install.DRY_RUN) = old_values
        self.assertEqual(config.read_bytes(), before)
        self.assertEqual(
            {p.relative_to(staged): p.read_bytes() for p in staged.rglob("*") if p.is_file()},
            staged_before,
        )
        self.assertFalse(backup.exists())

    def test_remove_config_failure_restores_kext_with_rename(self):
        config = self.efi / "EFI/OC/config.plist"
        config.write_bytes(plistlib.dumps({"Kernel": {"Add": [
            {"BundlePath": "Raphaeli.kext", "Enabled": True}]}}))
        staged = self.efi / "EFI/OC/Kexts/Raphaeli.kext"
        self._make_kext(staged)
        backup = staged.parent / "Raphaeli.kext.raphaeli-remove"
        before = config.read_bytes()
        old_values = (oc_install.CONFIG, oc_install.KEXTS_DIR, oc_install.DRY_RUN)
        try:
            oc_install.CONFIG = str(config)
            oc_install.KEXTS_DIR = str(staged.parent)
            oc_install.DRY_RUN = False
            real_replace = oc_install.os.replace
            with patch.object(oc_install, "save_config", side_effect=OSError("simulated config failure")), \
                    patch.object(oc_install.os, "replace", wraps=real_replace) as replace:
                with self.assertRaises(OSError):
                    oc_install.action_remove()
        finally:
            (oc_install.CONFIG, oc_install.KEXTS_DIR, oc_install.DRY_RUN) = old_values
        self.assertEqual(config.read_bytes(), before)
        self.assertTrue(staged.is_dir())
        self.assertFalse(backup.exists())
        self.assertIn(call(str(backup), str(staged)), replace.call_args_list)

    def test_duplicate_entries_keep_first_and_remove_only_raphaeli(self):
        config = self.efi / "EFI" / "OC" / "config.plist"
        config.write_bytes(plistlib.dumps({"Kernel": {"Add": [
            {"BundlePath": "Raphaeli.kext", "Enabled": True, "Marker": "keep",
             "MinKernel": "23.4.0", "MaxKernel": "23.99.99"},
            {"BundlePath": "Other.kext", "Enabled": True},
            {"BundlePath": "Raphaeli.kext", "Enabled": True, "Marker": "drop"},
        ]}}))
        result = self._run_add(
            "--target", "tahoe",
            "--kext-src", str(self.package / "target" / "Tahoe" / "Raphaeli.kext"),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        entries = plistlib.loads(config.read_bytes())["Kernel"]["Add"]
        self.assertEqual([entry["BundlePath"] for entry in entries], ["Raphaeli.kext", "Other.kext"])
        self.assertEqual(entries[0]["Marker"], "keep")
        self.assertEqual((entries[0]["MinKernel"], entries[0]["MaxKernel"]), ("25.0.0", "25.99.99"))

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
