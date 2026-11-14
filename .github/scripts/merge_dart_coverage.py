"""Merge Dart LCOV line records by canonical source path and line number."""

from __future__ import annotations

import argparse
from collections import defaultdict
from pathlib import Path
import posixpath

ROOT = Path(__file__).resolve().parents[2]


def source_path(value: str, root: Path) -> str:
    value = value.replace('\\', '/')
    prefix = root.resolve().as_posix().rstrip('/') + '/'
    comparable = value.lower() if len(value) > 1 and value[1] == ':' else value
    expected = prefix.lower() if len(prefix) > 1 and prefix[1] == ':' else prefix
    if comparable.startswith(expected):
        value = value[len(prefix):]
    elif value.startswith('/') or len(value) > 1 and value[1] == ':':
        raise ValueError(f'Coverage source is outside the checkout: {value}')
    normalized = posixpath.normpath(value)
    if normalized in ('', '.', '..') or normalized.startswith('../'):
        raise ValueError(f'Unsafe coverage source: {value}')
    return normalized


def merge(inputs: list[Path], output: Path, *, root: Path = ROOT) -> dict:
    if not inputs or len({path.resolve() for path in inputs}) != len(inputs):
        raise ValueError('Coverage inputs must be present and distinct')
    sources: dict[str, dict[int, int]] = defaultdict(lambda: defaultdict(int))
    checksums = {}
    for path in inputs:
        current = None
        current_lines = {}
        totals = {}
        records = 0
        for line in path.read_text(encoding='utf-8').splitlines():
            if not line or line.startswith('TN:'):
                continue
            if line.startswith('SF:'):
                if current is not None:
                    raise ValueError(f'Truncated coverage record in {path}')
                current = source_path(line[3:], root)
                sources[current]
                current_lines = {}
                totals = {}
            elif line.startswith('DA:'):
                fields = line[3:].split(',')
                if current is None or len(fields) not in (2, 3):
                    raise ValueError(f'Invalid line record in {path}: {line}')
                number, count = map(int, fields[:2])
                if number <= 0 or count < 0:
                    raise ValueError(f'Invalid line/count in {path}: {line}')
                if number in current_lines:
                    raise ValueError(f'Duplicate line in a coverage record in {path}: {number}')
                current_lines[number] = count
                if len(fields) == 3:
                    key = current, number
                    if key in checksums and checksums[key] != fields[2]:
                        raise ValueError(f'Different source checksums for {key}')
                    checksums[key] = fields[2]
                sources[current][number] += count
                records += 1
            elif line.startswith(('LF:', 'LH:')):
                if current is None or int(line[3:]) < 0:
                    raise ValueError(f'Invalid coverage total in {path}: {line}')
                key = line[:2]
                if key in totals:
                    raise ValueError(f'Duplicate coverage total in {path}: {key}')
                totals[key] = int(line[3:])
            elif line == 'end_of_record':
                if current is None:
                    raise ValueError(f'Unexpected record terminator in {path}')
                expected = {'LF': len(current_lines), 'LH': sum(count > 0 for count in current_lines.values())}
                if not current_lines or totals != expected:
                    raise ValueError(f'Empty coverage record or inconsistent line totals in {path}: {current}')
                current = None
            else:
                raise ValueError(f'Unsupported Dart line-coverage field in {path}: {line}')
        if current is not None or not records:
            raise ValueError(f'Truncated or empty coverage report: {path}')
    lines = []
    for source, coverage in sorted(sources.items()):
        lines.append(f'SF:{source}')
        for number, count in sorted(coverage.items()):
            checksum = checksums.get((source, number))
            lines.append(f'DA:{number},{count}' + (f',{checksum}' if checksum is not None else ''))
        lines.extend([f'LF:{len(coverage)}', f'LH:{sum(count > 0 for count in coverage.values())}', 'end_of_record'])
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    return {'files': len(sources), 'recorded_lines': sum(len(lines) for lines in sources.values()),
            'hit_lines': sum(count > 0 for lines in sources.values() for count in lines.values()), 'inputs': len(inputs)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('inputs', nargs='+', type=Path)
    args = parser.parse_args()
    print(merge(args.inputs, args.output))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
