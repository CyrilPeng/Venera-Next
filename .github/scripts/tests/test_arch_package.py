import importlib.util
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "build_arch_package.py"
spec = importlib.util.spec_from_file_location("arch_package", SCRIPT)
arch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(arch)


class ArchPackageTest(unittest.TestCase):
    def test_prepare_uses_repository_metadata_without_dart_packaging_tool(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            bundle = root / "bundle"
            (bundle / "lib").mkdir(parents=True)
            (bundle / "data").mkdir()
            (bundle / "venera-next").write_bytes(b"executable")
            (bundle / "lib/libflutter_linux_gtk.so").write_bytes(b"runtime")
            (bundle / "data/icudtl.dat").write_bytes(b"data")
            with patch.multiple(
                arch,
                BUNDLE_DIR=bundle,
                BUILD_LINUX_DIR=root,
                APP_DIR=root / "app",
                ARCH_DIR=root / "arch",
            ), patch.object(sys, "argv", [str(SCRIPT), "--prepare-only"]), patch.object(
                arch, "_run", side_effect=AssertionError("external tool invoked")
            ):
                arch.main()

            with tarfile.open(root / "arch/app.tar.gz") as archive:
                self.assertEqual(archive.extractfile("app/venera-next").read(), b"executable")
                self.assertEqual(archive.extractfile("app/data/icudtl.dat").read(), b"data")
                desktop = archive.extractfile("app/app.desktop").read().decode()
                self.assertIn("Exec=/usr/bin/venera-next_pkg/venera-next", desktop)
                self.assertIn("app/icon.png", archive.getnames())
            pkgbuild = (root / "arch/PKGBUILD").read_text(encoding="utf-8")
            self.assertIn("depends=('gtk3' 'webkit2gtk-4.1')", pkgbuild)
            self.assertIn("pkgname=venera-next", pkgbuild)
            self.assertTrue((root / "arch/Dockerfile").is_file())
            self.assertFalse((root / "app").exists())
            self.assertTrue((bundle / "venera-next").is_file())


if __name__ == "__main__":
    unittest.main()
