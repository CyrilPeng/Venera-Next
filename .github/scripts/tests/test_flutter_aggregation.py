import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from aggregate_flutter_tests import aggregate, require_jobs
from test_execution import partition_default


class CompleteFlutterAggregationTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.reports = self.root / 'reports'
        self.coverage = self.root / 'coverage/lcov.info'
        self.sources = {f'test/{name}_test.dart': 'void main() {}' for name in ['fast', 'a', 'b']}
        self.manifest = {
            'suites': {'default': {'include': ['test/**/*_test.dart']},
                       'fast': {'include': ['test/fast_test.dart']},
                       'tv': {'include': ['test/a_test.dart'],
                              'arguments': ['--flavor', 'tv', '--dart-define=EXPECT_TV=true']}},
            'default_execution': {'fast_suite': 'fast', 'shards': 2},
            'platform_skips': 'test/platform_skips.json',
        }
        (self.root / 'test').mkdir()
        text = json.dumps(self.manifest)
        (self.root / 'test/suites.json').write_text(text, encoding='utf-8')
        (self.root / 'test/platform_skips.json').write_text(
            json.dumps({'schema_version': 1, 'platforms': {'linux': []}}), encoding='utf-8')
        self.partitions = partition_default(self.manifest, self.sources, root=self.root)
        self.originals = {}
        for index, (group, files) in enumerate(self.partitions.items(), start=1):
            folder = self.reports / f'flutter-default-{group}'
            folder.mkdir(parents=True)
            counts = [(line, int(line == index)) for line in range(1, 4)]
            lcov = '\n'.join(['SF:lib/logic.dart', *[f'DA:{line},{count}' for line, count in counts],
                              'LF:3', 'LH:1', 'end_of_record']) + '\n'
            (folder / 'lcov.info').write_text(lcov, encoding='utf-8')
            report = {
                'schema_version': 2, 'complete': True, 'success': True, 'exit_code': 0,
                'source_commit': 'same-source', 'suite_manifest_sha256': hashlib.sha256(text.encode()).hexdigest(),
                'execution_group': group, 'platform': 'linux',
                'missing_files': [], 'unexpected_files': [], 'duplicate_files': [], 'zero_case_files': [],
                'protocol_errors': [], 'unfinished_tests': [], 'unknown_groups': [], 'errors': [],
                'command': ['flutter', 'test', '--no-pub', '--machine', '--coverage', *files],
                'expected_files': files, 'suites': [{'path': path, 'cases': 1} for path in files],
                'tests': [{'id': number, 'name': f'case for {path}', 'path': path, 'result': 'success', 'skipped': False}
                          for number, path in enumerate(files)],
                'cases': len(files), 'passed': len(files), 'skipped': 0, 'failed': 0,
                'skip_validation': {'unexpected': [], 'stale': [], 'documented': [], 'documented_cases_executed': []},
                'coverage_requested': True, 'coverage_sha256': hashlib.sha256((folder / 'lcov.info').read_bytes()).hexdigest(),
                'started_at': '2026-11-13T00:00:00+00:00', 'finished_at': '2026-11-13T00:00:02+00:00', 'wall_seconds': 2.0,
            }
            self.originals[group] = report
            self.write(group, report)
        self.first = next(iter(self.partitions))
        self.tv_file = 'test/a_test.dart'
        self.tv = copy.deepcopy(self.originals[self.first])
        self.tv.update(execution_group='tv', coverage_requested=False, coverage_sha256=None,
                       command=['flutter', 'test', '--no-pub', '--machine',
                                *self.manifest['suites']['tv']['arguments'], self.tv_file],
                       expected_files=[self.tv_file], suites=[{'path': self.tv_file, 'cases': 1}],
                       tests=[{'id': 0, 'name': 'TV behavior', 'path': self.tv_file,
                               'result': 'success', 'skipped': False}],
                       cases=1, passed=1, skipped=0, failed=0)
        self.tv_folder = self.reports / 'flutter-tv-test-runs'
        self.tv_folder.mkdir()
        self.write_tv(self.tv)

    def write_tv(self, report):
        (self.tv_folder / 'summary.json').write_text(json.dumps(report), encoding='utf-8')

    def write(self, group, report):
        (self.reports / f'flutter-default-{group}/summary.json').write_text(json.dumps(report), encoding='utf-8')

    def aggregate(self):
        return aggregate(self.reports, self.coverage, self.manifest, self.sources, root=self.root, commit='same-source')

    def test_complete_union_merges_coverage_without_repeating_the_denominator(self):
        result = self.aggregate()
        self.assertEqual((result['files'], result['cases'], result['passed']), (3, 3, 3))
        self.assertEqual((result['coverage']['recorded_lines'], result['coverage']['hit_lines']), (3, 3))
        self.assertEqual((result['tv']['files'], result['tv']['cases']), (1, 1))

    def test_each_required_job_rejects_failure_cancellation_skip_or_missing_state(self):
        expected = {name: {'result': 'success'} for name in ['flutter-fast', 'flutter-native', 'flutter-full', 'flutter-tv']}
        require_jobs(expected)
        for name in expected:
            for state in ['failure', 'cancelled', 'skipped', None]:
                with self.subTest(name=name, state=state):
                    results = copy.deepcopy(expected)
                    results[name]['result'] = state
                    with self.assertRaises(ValueError):
                        require_jobs(results)
        with self.assertRaises(ValueError):
            require_jobs([])
        with self.assertRaises(ValueError):
            require_jobs({**expected, 'flutter-full': 'success'})

    def test_wrong_commit_manifest_platform_group_or_partial_execution_fails(self):
        changes = [{'source_commit': 'old-source'}, {'suite_manifest_sha256': 'old-manifest'},
                   {'platform': 'windows'}, {'execution_group': 'another-shard'}, {'complete': False},
                   {'expected_files': []}, {'unfinished_tests': [{'id': 99}]}, {'cases': 999}]
        for change in changes:
            with self.subTest(change=change):
                report = copy.deepcopy(self.originals[self.first])
                report.update(change)
                self.write(self.first, report)
                with self.assertRaises(ValueError):
                    self.aggregate()

    def test_filters_foreign_files_duplicate_cases_and_unexpected_skips_fail(self):
        original = self.originals[self.first]
        for kind in ['filter', 'foreign', 'duplicate', 'skip']:
            with self.subTest(kind=kind):
                report = copy.deepcopy(original)
                if kind == 'filter':
                    report['command'].append('--name=smoke')
                elif kind == 'foreign':
                    report['suites'][0]['path'] = 'test/foreign_test.dart'
                elif kind == 'duplicate':
                    report['tests'].append(dict(report['tests'][0]))
                else:
                    report['tests'][0]['skipped'] = True
                    report.update(passed=0, skipped=1)
                self.write(self.first, report)
                with self.assertRaises(ValueError):
                    self.aggregate()

    def test_missing_or_changed_coverage_and_missing_reports_fail(self):
        folder = self.reports / f'flutter-default-{self.first}'
        (folder / 'lcov.info').write_text('changed coverage', encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'coverage'):
            self.aggregate()
        (folder / 'summary.json').unlink()
        with self.assertRaises(OSError):
            self.aggregate()

    def test_unexpected_partition_cannot_disappear(self):
        (self.reports / 'flutter-default-extra').mkdir()
        with self.assertRaisesRegex(ValueError, 'unexpected default reports'):
            self.aggregate()

    def test_stale_platform_case_fails_even_if_the_report_claims_no_skip_errors(self):
        policy = {'schema_version': 1, 'platforms': {'linux': [
            {'path': self.partitions[self.first][0], 'cases': ['removed case'], 'reason': 'Original platform boundary'}]}}
        (self.root / 'test/platform_skips.json').write_text(json.dumps(policy), encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'stale platform skips'):
            self.aggregate()

    def test_tv_requires_actual_evidence_after_a_successful_job(self):
        require_jobs({name: {'result': 'success'} for name in
                      ['flutter-fast', 'flutter-native', 'flutter-full', 'flutter-tv']})
        (self.tv_folder / 'summary.json').unlink()
        with self.assertRaises(FileNotFoundError):
            self.aggregate()

    def test_tv_source_flavor_filter_and_skip_cannot_weaken_the_gate(self):
        for kind in ['source', 'flavor', 'flavor-override', 'define-override', 'filter', 'skip']:
            with self.subTest(kind=kind):
                report = copy.deepcopy(self.tv)
                if kind == 'source':
                    report['source_commit'] = 'other-source'
                elif kind == 'flavor':
                    report['command'] = ['flutter', 'test', '--machine', self.tv_file]
                elif kind == 'flavor-override':
                    report['command'].extend(['--flavor', 'mobile'])
                elif kind == 'define-override':
                    report['command'].extend(['--dart-define', 'EXPECT_TV=false'])
                elif kind == 'filter':
                    report['command'].append('--plain-name=one behavior')
                else:
                    report['tests'][0]['skipped'] = True
                    report.update(passed=0, skipped=1)
                self.write_tv(report)
                with self.assertRaises(ValueError):
                    self.aggregate()


if __name__ == '__main__':
    unittest.main()
