"""Require every default partition and merge only complete same-source coverage."""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

from merge_dart_coverage import merge
from test_execution import load_skip_policy, partition_default, validate_complete_arguments, validate_declared_arguments, validate_skips
from test_suites import ROOT, application_tests, load_manifest, paths, select_suite

REQUIRED_JOBS = ('flutter-fast', 'flutter-native', 'flutter-full', 'flutter-tv')
EMPTY_FIELDS = ('missing_files', 'unexpected_files', 'duplicate_files', 'zero_case_files',
                'protocol_errors', 'unfinished_tests', 'unknown_groups', 'errors')


def require_jobs(results: dict) -> None:
    if not isinstance(results, dict):
        raise ValueError('Required Flutter job results must be an object')
    invalid = {}
    for name in REQUIRED_JOBS:
        row = results.get(name)
        state = row.get('result') if isinstance(row, dict) else row
        if not isinstance(row, dict) or state != 'success':
            invalid[name] = state
    if invalid:
        raise ValueError(f'Required Flutter jobs did not succeed: {invalid}')


def validate_report(report: dict, name: str, expected: list[str], *, commit: str,
                    manifest_hash: str, policy: dict, coverage: bool,
                    arguments: list[str] | None = None) -> tuple[list[dict], dict]:
    if report.get('schema_version') != 2 or report.get('complete') is not True or report.get('success') is not True or report.get('exit_code') != 0:
        raise ValueError(f'Incomplete or failed execution: {name}')
    if (report.get('source_commit') != commit or report.get('suite_manifest_sha256') != manifest_hash or
            report.get('execution_group') != name or report.get('platform') != 'linux'):
        raise ValueError(f'Wrong source, manifest, group or platform in {name}')
    for field in EMPTY_FIELDS:
        if report.get(field) != []:
            raise ValueError(f'Execution integrity failed in {name}: {field}={report.get(field)}')
    command = report.get('command', [])
    validate_complete_arguments(command, coverage=coverage)
    if '--machine' not in command or coverage and '--coverage' not in command:
        raise ValueError(f'Machine execution and requested coverage are required in {name}')
    if arguments:
        validate_declared_arguments(command, arguments)
    owned = report.get('expected_files', [])
    suites = report.get('suites', [])
    loaded = [suite['path'] for suite in suites]
    if sorted(owned) != sorted(expected) or sorted(loaded) != sorted(expected):
        raise ValueError(f'Missing, duplicate or foreign files in {name}')
    rows = report.get('tests', [])
    identifiers = [case.get('id') for case in rows]
    if not rows or any(type(ident) is not int or ident < 0 for ident in identifiers) or len(set(identifiers)) != len(identifiers):
        raise ValueError(f'Missing or duplicate case records in {name}')
    if any(case['path'] not in expected or not isinstance(case.get('name'), str) or not case['name']
           or case.get('hidden') or case.get('result') != 'success' or type(case.get('skipped')) is not bool
           for case in rows):
        raise ValueError(f'Failed or foreign case records in {name}')
    by_file = Counter(case['path'] for case in rows)
    if any(type(suite.get('cases')) is not int or by_file[suite['path']] != suite['cases'] or not suite['cases'] for suite in suites):
        raise ValueError(f'Empty files or inconsistent case counts in {name}')
    counts = {'cases': len(rows), 'passed': sum(not case['skipped'] for case in rows),
              'skipped': sum(case['skipped'] for case in rows), 'failed': 0}
    if any(type(report.get(key)) is not int or report[key] != value for key, value in counts.items()):
        raise ValueError(f'Inconsistent result totals in {name}')
    skips = validate_skips(report, policy, 'linux', expected)
    if skips['unexpected'] or skips['stale'] or report.get('skip_validation') != skips:
        raise ValueError(f'Unexpected or stale platform skips in {name}')
    return rows, counts


def aggregate(reports: Path, coverage: Path, manifest: dict, sources: dict[str, str], *,
              root: Path = ROOT, commit: str) -> dict:
    partitions = partition_default(manifest, sources, root=root)
    if not partitions:
        raise ValueError('Complete default execution partitions are not configured')
    expected_folders = {f'flutter-default-{name}' for name in partitions}
    found = {path.name for path in reports.iterdir() if path.is_dir() and path.name.startswith('flutter-default-')}
    if found != expected_folders:
        raise ValueError(f'Missing or unexpected default reports: missing={expected_folders - found}, extra={found - expected_folders}')
    manifest_hash = hashlib.sha256((root / 'test/suites.json').read_bytes()).hexdigest()
    policy = load_skip_policy(manifest, root=root, sources=sources)
    groups = []
    cases = []
    inputs = []
    for name, expected in partitions.items():
        folder = reports / f'flutter-default-{name}'
        report = json.loads((folder / 'summary.json').read_text(encoding='utf-8'))
        rows, counts = validate_report(report, name, expected, commit=commit,
                                       manifest_hash=manifest_hash, policy=policy, coverage=True)
        lcov = folder / 'lcov.info'
        if report.get('coverage_requested') is not True or not lcov.is_file() or report.get('coverage_sha256') != hashlib.sha256(lcov.read_bytes()).hexdigest():
            raise ValueError(f'Missing, changed or unrequested coverage in {name}')
        inputs.append(lcov)
        cases.extend({**case, 'execution_group': name} for case in rows)
        groups.append({'execution_group': name, 'files': len(expected), **counts,
                       'started_at': report['started_at'], 'finished_at': report['finished_at'],
                       'wall_seconds': report['wall_seconds']})
    tv_expected = select_suite(manifest, 'tv', sources, root=root)
    tv_report = json.loads((reports / 'flutter-tv-test-runs/summary.json').read_text(encoding='utf-8'))
    tv_rows, tv_counts = validate_report(tv_report, 'tv', tv_expected, commit=commit,
                                       manifest_hash=manifest_hash, policy=policy, coverage=False,
                                       arguments=manifest['suites']['tv']['arguments'])
    tv_summary = {'files': len(tv_expected), **tv_counts, 'source_commit': commit,
                  'started_at': tv_report['started_at'], 'finished_at': tv_report['finished_at'],
                  'wall_seconds': tv_report['wall_seconds'], 'tests': tv_rows}
    coverage_summary = merge(inputs, coverage, root=root)
    names = Counter(case['name'] for case in cases)
    return {'schema_version': 2, 'success': True, 'source_commit': commit,
            'suite_manifest_sha256': manifest_hash, 'platform': 'linux',
            'files': sum(group['files'] for group in groups),
            'cases': len(cases), 'passed': sum(not case['skipped'] for case in cases),
            'skipped': sum(case['skipped'] for case in cases), 'failed': 0,
            'name_counter_sha256': hashlib.sha256(json.dumps(sorted(names.items()), ensure_ascii=False).encode()).hexdigest(),
            'coverage': coverage_summary, 'groups': groups, 'tests': cases, 'tv': tv_summary}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reports', type=Path, required=True)
    parser.add_argument('--coverage-output', type=Path, default=ROOT / 'coverage/lcov.info')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/test-audit/aggregate')
    parser.add_argument('--github-summary', action='store_true')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    try:
        results = json.loads(os.environ['REQUIRED_RESULTS'])
        require_jobs(results)
        manifest = load_manifest()
        sources = {path: (ROOT / path).read_text(encoding='utf-8') for path in application_tests(paths())}
        commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
        result = aggregate(args.reports, args.coverage_output, manifest, sources, root=ROOT, commit=commit)
        result['required_jobs'] = results
        print(f"Default Flutter: {result['passed']} passed / {result['skipped']} documented skips / {result['files']} files")
        if args.github_summary:
            destination = os.environ['GITHUB_STEP_SUMMARY']
            rows = ['## 完整 Flutter 验证', '', '| 执行组 | 文件 | 通过 | 跳过 | 测试墙钟秒 |', '| --- | ---: | ---: | ---: | ---: |']
            rows.extend(f"| {group['execution_group']} | {group['files']} | {group['passed']} | {group['skipped']} | {group['wall_seconds']:.3f} |"
                        for group in result['groups'])
            rows.extend(['', f"普通平台并集：{result['cases']} 项，来源 `{commit}`；覆盖 {result['coverage']['hit_lines']}/{result['coverage']['recorded_lines']} 行。",
                         '各组墙钟不可相加作为关键路径；TV、平台与设备验收另行记录。', ''])
            with open(destination, 'a', encoding='utf-8') as output:
                output.write('\n'.join(rows))
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        result = {'schema_version': 2, 'success': False, 'error': str(error)}
        print(f'Flutter aggregation failed: {error}', file=sys.stderr, flush=True)
    (args.output / 'summary.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    return 0 if result['success'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
