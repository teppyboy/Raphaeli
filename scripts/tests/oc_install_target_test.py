#!/usr/bin/env python3
import importlib.util
import plistlib
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
        for name in ("Sequoia", "Tahoe"):
            self._make_kext(self.package / "target" / name / "Raphaeli.kext")

    def tearDown(self):
        self.tmp.cleanup()

    def _make_kext(self, path):
        (path / "Contents" / "MacOS").mkdir(parents=True)
        (path / "Contents" / "Info.plist").write_bytes(
            plistlib.dumps({"CFBundleExecutable": "Raphaeli"})
        )
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

    def test_kext_override_requires_known_target_and_uses_override(self):
        override = self.root / "override" / "Raphaeli.kext"
        self._make_kext(override)
        result = self._run_add("--target", "sequoia", "--kext-src", str(override))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.efi / "EFI" / "OC" / "Kexts" / "Raphaeli.kext").is_dir())


if __name__ == "__main__":
    unittest.main()
