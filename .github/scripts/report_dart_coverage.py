#!/usr/bin/env python3
"""Summarize Dart LCOV line coverage for CI."""

from __future__ import annotations

import argparse
import os
from pathlib import Path


def read_line_coverage(path: Path) -> tuple[int, int]:
    hit = 0
    total = 0
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        if not raw_line.startswith("DA:"):
            continue
        fields = raw_line[3:].split(",")
        if len(fields) < 2:
            raise ValueError(f"Invalid LCOV line record: {raw_line}")
        try:
            count = int(fields[1])
        except ValueError as error:
            raise ValueError(f"Invalid LCOV hit count: {raw_line}") from error
        total += 1
        if count > 0:
            hit += 1
    if total == 0:
        raise ValueError("LCOV report does not contain line coverage records")
    return hit, total


def format_summary(hit: int, total: int) -> str:
    percentage = hit / total * 100
    return f"Dart line coverage: {percentage:.2f}% ({hit}/{total})"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("lcov", type=Path)
    parser.add_argument("--github-summary", action="store_true")
    args = parser.parse_args()

    hit, total = read_line_coverage(args.lcov)
    summary = format_summary(hit, total)
    print(summary)

    if args.github_summary:
        summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
        if not summary_path:
            raise RuntimeError("GITHUB_STEP_SUMMARY is not set")
        with Path(summary_path).open("a", encoding="utf-8") as output:
            output.write(f"## Dart coverage\n\n{summary}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
