from collections import Counter
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from test_execution import load_skip_policy, partition_default, validate_skips


class ExecutionPartitionTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.sources = {f'test/{name}_test.dart': 'void main() {}' for name in ['fast', 'a', 'b', 'c']}
        for name, contents in self.sources.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents, encoding='utf-8')
        self.manifest = {
            'suites': {'default': {'include': ['test/**/*_test.dart']},
                       'fast': {'include': ['test/fast_test.dart']}},
            'default_execution': {'fast_suite': 'fast', 'shards': 2,
                                  'weights_ms': {'test/a_test.dart': 10000, 'test/b_test.dart': 9000}},
            'platform_skips': 'test/platform_skips.json',
        }
        self.policy = {'schema_version': 1, 'platforms': {'windows': [
            {'path': 'test/a_test.dart', 'cases': ['symbolic link boundary'], 'reason': 'Host symlink privilege'}]}}

    def partitions(self):
        return partition_default(self.manifest, self.sources, root=self.root)

    def policy_file(self):
        (self.root / 'test/platform_skips.json').write_text(json.dumps(self.policy), encoding='utf-8')
        return load_skip_policy(self.manifest, root=self.root, sources=self.sources)

    def test_fast_and_measured_shards_cover_each_file_once_and_separate_heavy_files(self):
        parts = self.partitions()
        assigned = Counter(path for files in parts.values() for path in files)
        self.assertEqual(set(assigned), set(self.sources))
        self.assertTrue(all(count == 1 for count in assigned.values()))
        self.assertEqual(parts['fast'], ['test/fast_test.dart'])
        owners = {path: name for name, paths in parts.items() for path in paths}
        self.assertNotEqual(owners['test/a_test.dart'], owners['test/b_test.dart'])

    def test_new_files_automatically_enter_the_full_union(self):
        self.sources['test/new_test.dart'] = 'void main() {}'
        parts = self.partitions()
        self.assertIn('test/new_test.dart', {path for files in parts.values() for path in files})
        self.assertNotIn('test/new_test.dart', parts['fast'])

    def test_stale_weights_missing_fast_and_empty_shards_fail(self):
        original = copy.deepcopy(self.manifest)
        for update in [
            {'weights_ms': {'test/deleted_test.dart': 1000}},
            {'shards': 0}, {'shards': 4}, {'fast_suite': 'unknown'}, {'fast_suite': 'default'},
        ]:
            with self.subTest(update=update):
                self.manifest = copy.deepcopy(original)
                self.manifest['default_execution'].update(update)
                with self.assertRaises(ValueError):
                    self.partitions()

    def test_invalid_skip_ownership_and_missing_reasons_fail(self):
        original = copy.deepcopy(self.policy)
        for update in [{'path': 'test/deleted_test.dart'}, {'reason': ''},
                       {'cases': ['same', 'same']}, {'cases': []}]:
            with self.subTest(update=update):
                self.policy = copy.deepcopy(original)
                self.policy['platforms']['windows'][0].update(update)
                with self.assertRaises(ValueError):
                    self.policy_file()
        self.policy = {'schema_version': 1, 'platforms': {'unknown': []}}
        with self.assertRaises(ValueError):
            self.policy_file()

    def test_documented_limitation_can_execute_but_new_or_stale_skips_fail(self):
        policy = self.policy_file()
        selected = ['test/a_test.dart']
        case = {'path': selected[0], 'name': 'symbolic link boundary', 'skipped': True}
        report = {'tests': [case], 'suites': [{'path': selected[0]}]}
        result = validate_skips(report, policy, 'windows', selected)
        self.assertFalse(result['unexpected'] or result['stale'])
        case['skipped'] = False
        self.assertEqual(len(validate_skips(report, policy, 'windows', selected)['documented_cases_executed']), 1)
        case.update(skipped=True, name='unexpected platform skip')
        result = validate_skips(report, policy, 'windows', selected)
        self.assertEqual(len(result['unexpected']), 1)
        self.assertEqual(len(result['stale']), 1)
        case['name'] = 'symbolic link boundary'
        report['tests'].append(dict(case))
        self.assertEqual(len(validate_skips(report, policy, 'windows', selected)['unexpected']), 1)


if __name__ == '__main__':
    unittest.main()
