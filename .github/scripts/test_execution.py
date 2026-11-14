"""Validate complete default partitions and documented platform skips."""

from __future__ import annotations

from collections import Counter
import json
from pathlib import Path

from test_suites import ROOT, select_suite

CASE_FILTERS = ('--name', '--plain-name', '--tags', '--exclude-tags',
                '--total-shards', '--shard-index', '-n', '-N', '-t', '-x')
COVERAGE_FILTERS = ('--exclude-coverage', '--coverage-package', '--no-coverage')


def validate_complete_arguments(command: list[str], *, coverage: bool = False) -> None:
    if not isinstance(command, list) or not command or any(not isinstance(arg, str) for arg in command):
        raise ValueError('Complete test execution requires an argument array')
    forbidden = CASE_FILTERS + (COVERAGE_FILTERS if coverage else ())
    if any(arg == option or arg.startswith(option + '=') or
           not option.startswith('--') and arg.startswith(option)
           for option in forbidden for arg in command):
        raise ValueError('Test or coverage filters cannot reduce a complete declared suite')


def validate_declared_arguments(command: list[str], arguments: list[str]) -> None:
    if not any(command[index:index + len(arguments)] == arguments for index in range(len(command))):
        raise ValueError('Missing declared flavor or compilation arguments')
    # A second flag or define can override the earlier declared value even
    # though the original contiguous sequence still appears in the command.
    declared = {}
    for index, arg in enumerate(arguments):
        if arg == '--flavor':
            declared['--flavor'] = arguments[index + 1]
        elif arg.startswith('--dart-define='):
            key, value = arg[len('--dart-define='):].split('=', 1)
            declared[key] = value
    observed = {key: [] for key in declared}
    for index, arg in enumerate(command):
        if arg == '--flavor' and '--flavor' in observed:
            observed['--flavor'].append(command[index + 1] if index + 1 < len(command) else None)
        elif arg.startswith('--flavor=') and '--flavor' in observed:
            observed['--flavor'].append(arg.split('=', 1)[1])
        elif arg == '--dart-define' or arg.startswith('--dart-define='):
            value = command[index + 1] if arg == '--dart-define' and index + 1 < len(command) else arg[len('--dart-define='):]
            key, separator, value = value.partition('=')
            if separator and key in observed:
                observed[key].append(value)
    if any(observed[key] != [value] for key, value in declared.items()):
        raise ValueError('Declared flavor or compilation arguments were overridden')


def partition_default(manifest: dict, sources: dict[str, str], *, root: Path = ROOT) -> dict[str, list[str]]:
    config = manifest.get('default_execution')
    if config is None:
        return {}
    if not isinstance(config, dict):
        raise ValueError('Default execution must be an object')
    default = set(select_suite(manifest, 'default', sources, root=root))
    fast_name = config.get('fast_suite', 'fast')
    if fast_name == 'default':
        raise ValueError('Fast execution needs its own verified suite')
    fast = select_suite(manifest, fast_name, sources, root=root)
    if set(fast) - default:
        raise ValueError('Fast execution contains files outside the default suite')
    count = config.get('shards')
    fallback = config.get('default_weight_ms', 2000)
    if type(count) is not int or count < 1 or type(fallback) is not int or fallback < 1:
        raise ValueError('Shard count and default weight must be positive integers')
    weights = config.get('weights_ms', {})
    if not isinstance(weights, dict) or set(weights) - default:
        raise ValueError('Default execution contains stale runtime weights')
    if any(type(value) is not int or value < 1 for value in weights.values()):
        raise ValueError('Runtime weights must be positive integer milliseconds')
    parts = {'fast': fast, **{f'shard-{index + 1}': [] for index in range(count)}}
    costs = [0] * count
    for path in sorted(default - set(fast), key=lambda path: (-weights.get(path, fallback), path)):
        index = min(range(count), key=lambda index: (costs[index], index))
        parts[f'shard-{index + 1}'].append(path)
        costs[index] += weights.get(path, fallback)
    if any(not files for files in parts.values()):
        raise ValueError('Every default execution group must contain tests')
    assigned = Counter(path for files in parts.values() for path in files)
    if set(assigned) != default or any(value != 1 for value in assigned.values()):
        raise ValueError('Default partitions must cover each test file exactly once')
    return {name: sorted(files) for name, files in parts.items()}


def load_skip_policy(manifest: dict, *, root: Path = ROOT, sources: dict[str, str] | None = None) -> dict:
    name = manifest.get('platform_skips')
    if name is None:
        return {}
    if not isinstance(name, str):
        raise ValueError('Platform skip policy requires a file path')
    path = (root / name).resolve()
    if not path.is_relative_to((root / 'test').resolve()):
        raise ValueError('Platform skip policy must stay inside test/')
    data = json.loads(path.read_text(encoding='utf-8'))
    if data.get('schema_version') != 1 or not isinstance(data.get('platforms'), dict):
        raise ValueError('Unsupported platform skip policy')
    for platform, rows in data['platforms'].items():
        if platform not in ('linux', 'windows', 'macos') or not isinstance(rows, list):
            raise ValueError('Invalid skip platform or rows')
        seen = set()
        for row in rows:
            if not isinstance(row, dict) or not isinstance(row.get('path'), str) or not row.get('reason'):
                raise ValueError('Every platform skip requires its path and reason')
            cases = row.get('cases')
            if not isinstance(cases, list) or not cases or any(not isinstance(case, str) or not case for case in cases):
                raise ValueError('Every platform skip requires its actual case names')
            if row['path'] in seen or len(set(cases)) != len(cases):
                raise ValueError('Duplicate platform skip ownership')
            seen.add(row['path'])
            if sources is not None and row['path'] not in sources:
                raise ValueError(f'Stale platform skip path: {row["path"]}')
    return data['platforms']


def validate_skips(summary: dict, policy: dict, platform: str, expected: list[str] | None) -> dict:
    files = set(expected or (row['path'] for row in summary['suites']))
    allowed = {(row['path'], case): row['reason'] for row in policy.get(platform, [])
               if row['path'] in files for case in row['cases']}
    observed = Counter((case['path'], case['name']) for case in summary['tests'])
    stale = sorted(key for key in allowed if key not in observed)
    skipped = Counter((case['path'], case['name']) for case in summary['tests'] if case['skipped'])
    unexpected = sorted(key for key, count in skipped.items() if key not in allowed or count > 1)
    documented = [{'path': path, 'name': name, 'reason': allowed[path, name]}
                  for path, name in skipped if (path, name) in allowed]
    # A documented platform/privilege limitation may become executable on a
    # capable host. More execution is accepted; stale case names still fail.
    executed = sorted(key for key in allowed if key in observed and key not in skipped)
    return {'unexpected': unexpected, 'stale': stale, 'documented': documented,
            'documented_cases_executed': executed}
