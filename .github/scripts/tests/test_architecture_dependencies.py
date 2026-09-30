import importlib.util
import tempfile
import unittest
from pathlib import Path


SPEC = importlib.util.spec_from_file_location(
    "architecture_dependencies",
    Path(__file__).resolve().parents[1] / "check_architecture_dependencies.py",
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ArchitectureDependenciesTest(unittest.TestCase):
    def test_conditional_directives_and_comments(self):
        text = """
        // import 'fake.dart';
        /* export 'fake2.dart'; */
        import 'stub.dart' if (dart.library.io) 'native.dart';
        export 'a.dart' if (dart.library.html) 'b.dart';
        part 'child.dart';
        part of 'parent.dart';
        """
        self.assertEqual(list(MODULE.directives(text)),
                         ['stub.dart', 'native.dart', 'a.dart', 'b.dart', 'child.dart'])

    def test_relative_package_and_part_resolution(self):
        with tempfile.TemporaryDirectory() as directory:
            lib = Path(directory)
            (lib / 'a.dart').write_text(
                "import 'package:venera_next/b.dart'; part 'c.dart';", encoding='utf-8')
            (lib / 'b.dart').write_text("export 'c.dart';", encoding='utf-8')
            (lib / 'c.dart').write_text("part of 'a.dart';", encoding='utf-8')
            self.assertEqual(MODULE.graph_for(lib), {
                'a.dart': {'b.dart', 'c.dart'}, 'b.dart': {'c.dart'}, 'c.dart': set()})

    def test_directive_text_inside_string_is_not_a_dependency(self):
        self.assertEqual(list(MODULE.directives(
            '''const example = "import 'fake.dart';"; import 'real.dart';''')),
            ['real.dart'])

    def test_transitive_ui_dependency_is_rejected(self):
        graph = {'api.dart': {'barrel.dart'}, 'barrel.dart': {'page.dart'}, 'page.dart': set()}
        baseline = {'allowed_feature_edges': [], 'business_entrypoints': ['api.dart'],
                    'ui_files': ['page.dart']}
        self.assertEqual(MODULE.violations(graph, baseline),
                         ['Business entry point reaches UI: api.dart -> page.dart'])

    def test_new_edge_is_rejected_but_existing_edge_is_allowed(self):
        graph = {'features/a/a.dart': {'features/b/b.dart', 'features/c/c.dart'}}
        self.assertEqual(MODULE.violations(graph, {'allowed_feature_edges': [['a', 'b']]}),
                         ['New feature dependency: a -> c'])

    def test_cycles_group_overlapping_loops(self):
        self.assertEqual(MODULE.cycles({('a', 'b'), ('b', 'a'), ('b', 'c'),
                                        ('c', 'b'), ('d', 'e')}), [['a', 'b', 'c']])

    def test_missing_business_entrypoint_is_rejected(self):
        self.assertEqual(MODULE.violations({}, {'allowed_feature_edges': [],
                         'business_entrypoints': ['missing.dart']}),
                         ['Missing business entry point: missing.dart'])

    def test_reader_cannot_reintroduce_dynamic_setting_calls(self):
        with tempfile.TemporaryDirectory() as directory:
            lib = Path(directory)
            reader = lib / 'features/reader'
            reader.mkdir(parents=True)
            source = reader / 'view.dart'
            source.write_text("final value = settings.getReaderSetting(id, key, 'mode');")
            self.assertEqual(MODULE.reader_settings_violations(lib),
                             ['Reader must use typed settings: features/reader/view.dart'])
            source.write_text("final value = reader.preferences.readerMode;")
            self.assertEqual(MODULE.reader_settings_violations(lib), [])


if __name__ == '__main__':
    unittest.main()
