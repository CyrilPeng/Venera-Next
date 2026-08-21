import tempfile
import unittest
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

from report_dart_coverage import format_summary, read_line_coverage


class DartCoverageTest(unittest.TestCase):
    def test_reads_line_records_across_files(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            report = Path(temp_dir) / "lcov.info"
            report.write_text(
                "SF:lib/a.dart\nDA:1,1\nDA:2,0\nend_of_record\n"
                "SF:lib/b.dart\nDA:5,3\nend_of_record\n",
                encoding="utf-8",
            )

            self.assertEqual(read_line_coverage(report), (2, 3))
            self.assertEqual(
                format_summary(2, 3),
                "Dart line coverage: 66.67% (2/3)",
            )

    def test_rejects_report_without_line_records(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            report = Path(temp_dir) / "lcov.info"
            report.write_text("SF:lib/a.dart\nend_of_record\n", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "line coverage records"):
                read_line_coverage(report)


if __name__ == "__main__":
    unittest.main()
