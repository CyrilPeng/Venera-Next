import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[3]
SCRIPT_PATH = ROOT / ".github" / "scripts" / "check_structure_imports.py"
SPEC = importlib.util.spec_from_file_location("check_structure_imports", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class StructureImportsTest(unittest.TestCase):
    def test_reviewed_business_entries_are_not_redirected_to_ui_barrels(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lib = root / 'lib'
            source = lib / 'app_runtime/owner.dart'
            source.parent.mkdir(parents=True)
            targets = {
                (lib / path.relative_to(MODULE.LIB_DIR)).resolve():
                (lib / target.relative_to(MODULE.LIB_DIR)).resolve()
                for path, target in MODULE.FEATURE_ENTRYPOINT_TARGETS.items()
            }
            source.write_text('''
                import 'package:venera_next/features/history/history_image_provider.dart';
                import 'package:venera_next/features/history/image_favorites_provider.dart';
                import 'package:venera_next/features/local_comics/download.dart';
                import 'package:venera_next/features/history/history_api.dart';
            ''', encoding='utf-8')
            with patch.multiple(MODULE, ROOT=root.resolve(), LIB_DIR=lib.resolve(),
                                FEATURE_ENTRYPOINT_TARGETS=targets):
                self.assertEqual(MODULE._scan_feature_entrypoint_violations(), set())
                # A business entry does not grant access to UI implementation files.
                source.write_text(
                    "import 'package:venera_next/features/comic_details/comic_page.dart';",
                    encoding='utf-8')
                self.assertEqual(MODULE._scan_feature_entrypoint_violations(), {
                    'lib/app_runtime/owner.dart -> lib/features/comic_details/comic_page.dart '
                    '(use lib/features/comic_details/comic_details.dart)'})
                source.write_text(
                    "import 'package:venera_next/features/history/image_favorites_models.dart';",
                    encoding='utf-8')
                self.assertEqual(MODULE._scan_feature_entrypoint_violations(), {
                    'lib/app_runtime/owner.dart -> lib/features/history/image_favorites_models.dart '
                    '(use lib/features/history/history_api.dart)'})

    def test_structure_boundaries_are_clean(self):
        self.assertEqual(MODULE._scan_restricted_imports(), set())
        self.assertEqual(MODULE._scan_forbidden_feature_dependencies(), set())
        self.assertEqual(MODULE._scan_feature_entrypoint_violations(), set())

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
