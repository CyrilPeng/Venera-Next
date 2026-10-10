import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "prepare_linux_test_libraries.py"
SPEC = importlib.util.spec_from_file_location("linux_test_libraries", SCRIPT)
LIBRARIES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LIBRARIES)


class PackagePathsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.config = self.root / ".dart_tool/package_config.json"
        self.config.parent.mkdir()
        self.packages = []
        for name in LIBRARIES.PACKAGES:
            path = self.root / "package cache" / name
            source = "cxx/quickjs.cmake" if name == "flutter_qjs" else "src/CMakeLists.txt"
            (path / source).parent.mkdir(parents=True)
            (path / source).write_text("", encoding="utf-8")
            self.packages.append({"name": name, "rootUri": path.as_uri()})

    def resolve(self):
        self.config.write_text(json.dumps({"packages": self.packages}), encoding="utf-8")
        return LIBRARIES.package_paths(self.config)

    def test_resolves_uri_and_relative_package_roots_with_spaces(self):
        self.packages[0]["rootUri"] = "../package%20cache/flutter_qjs"
        self.packages.append({"name": "unrelated", "rootUri": "https://example.com/"})
        paths = self.resolve()
        self.assertEqual(set(paths), set(LIBRARIES.PACKAGES))
        self.assertEqual(paths["flutter_qjs"], self.root / "package cache/flutter_qjs")
        self.assertEqual(paths["zip_flutter"], self.root / "package cache/zip_flutter")

    def test_missing_dependency_requires_pub_get(self):
        self.packages.pop()
        with self.assertRaisesRegex(ValueError, "missing packages.*lodepng_flutter"):
            self.resolve()

    def test_missing_native_sources_fail_before_build(self):
        (self.root / "package cache/zip_flutter/src/CMakeLists.txt").unlink()
        with self.assertRaisesRegex(ValueError, "zip_flutter: native sources missing"):
            self.resolve()

    def test_remote_package_root_is_rejected(self):
        self.packages[0]["rootUri"] = "https://example.com/flutter_qjs"
        with self.assertRaisesRegex(ValueError, "expected a local package root"):
            self.resolve()


if __name__ == "__main__":
    unittest.main()
