import importlib.util
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SCRIPT_PATH = ROOT / ".github" / "scripts" / "check_structure_imports.py"
SPEC = importlib.util.spec_from_file_location("check_structure_imports", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class StructureImportsTest(unittest.TestCase):
    def test_structure_boundaries_are_clean(self):
        self.assertEqual(MODULE._scan_restricted_imports(), set())
        self.assertEqual(MODULE._scan_forbidden_feature_dependencies(), set())

    def test_feature_dependency_report_contains_current_edges(self):
        edges = MODULE._feature_dependency_edges()
        self.assertGreaterEqual(
            edges[("features/comic_details", "features/comic_source")],
            1,
        )
        self.assertNotIn(("features/comic_source", "features/sync"), edges)
        self.assertNotIn(
            ("features/comic_source", "features/webdav_library"),
            edges,
        )
        self.assertNotIn(
            ("features/comic_widgets", "features/favorites"),
            edges,
        )
        self.assertNotIn(
            ("features/comic_widgets", "features/history"),
            edges,
        )
        self.assertNotIn(
            ("features/comic_widgets", "features/local_comics"),
            edges,
        )


if __name__ == "__main__":
    unittest.main()
