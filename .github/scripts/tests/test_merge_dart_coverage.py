from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from merge_dart_coverage import merge, source_path


def record(source, counts):
    return '\n'.join([f'SF:{source}', *[f'DA:{line},{count}' for line, count in counts],
                      f'LF:{len(counts)}', f'LH:{sum(count > 0 for _, count in counts)}', 'end_of_record']) + '\n'


class DartCoverageMergeTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.output = self.root / 'coverage/lcov.info'

    def write(self, name, text):
        path = self.root / name
        path.write_text(text, encoding='utf-8')
        return path

    def test_overlapping_paths_and_lines_share_one_denominator_and_sum_counts(self):
        first = self.write('first.info', record('lib\\reader.dart', [(1, 2), (2, 0)]))
        second = self.write('second.info', record(str(self.root / 'lib/reader.dart'), [(1, 3), (2, 1), (3, 0)])
                            + record('lib/other.dart', [(8, 1)]))
        result = merge([first, second], self.output, root=self.root)
        self.assertEqual((result['files'], result['recorded_lines'], result['hit_lines']), (2, 4, 3))
        contents = self.output.read_text(encoding='utf-8')
        self.assertEqual(contents.count('SF:lib/reader.dart'), 1)
        self.assertIn('DA:1,5\nDA:2,1\nDA:3,0\nLF:3\nLH:2', contents)

    def test_empty_truncated_duplicate_and_invalid_line_reports_fail(self):
        invalid = ['', 'SF:lib/a.dart\nDA:1,1\n',
                   record('lib/a.dart', [(1, -1)]),
                   'SF:lib/a.dart\nDA:1,1\nDA:1,2\nLF:2\nLH:2\nend_of_record\n',
                   'SF:lib/a.dart\nDA:1,1\nLF:99\nLH:1\nend_of_record\n']
        for index, text in enumerate(invalid):
            with self.subTest(index=index):
                path = self.write(f'invalid-{index}.info', text)
                with self.assertRaises(ValueError):
                    merge([path], self.output, root=self.root)
        valid = self.write('valid.info', record('lib/a.dart', [(1, 1)]))
        with self.assertRaises(ValueError):
            merge([valid, valid], self.output, root=self.root)

    def test_different_source_checksums_cannot_be_combined(self):
        first = self.write('first.info', 'SF:lib/a.dart\nDA:1,1,abc\nLF:1\nLH:1\nend_of_record\n')
        second = self.write('second.info', 'SF:lib/a.dart\nDA:1,2,def\nLF:1\nLH:1\nend_of_record\n')
        with self.assertRaisesRegex(ValueError, 'Different source checksums'):
            merge([first, second], self.output, root=self.root)

    def test_sources_cannot_escape_the_checkout(self):
        for value in ['../outside.dart', '/outside.dart', 'Z:/another/checkout.dart']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                source_path(value, self.root)


if __name__ == '__main__':
    unittest.main()
