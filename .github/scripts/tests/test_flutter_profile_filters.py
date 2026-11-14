"""A declared complete suite cannot hide cases while all its files still load."""

from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import run_flutter_tests


class CompleteProfileArgumentsTest(unittest.TestCase):
    def test_profile_filters_fail_before_launching_a_subset(self):
        scenarios = [(['--name', 'some behavior'], []),
                     (['--plain-name=some behavior'], []),
                     (['--tags', 'smoke'], []),
                     (['--exclude-tags=slow'], []),
                     (['-none behavior'], []),
                     (['-tsmoke'], []),
                     (['--total-shards', '2', '--shard-index', '0'], []),
                     (['--coverage-package=partial'], ['--coverage']),
                     (['--no-coverage'], ['--coverage'])]
        for arguments, options in scenarios:
            with self.subTest(arguments=arguments):
                manifest = {'suites': {'default': {
                    'platforms': ['windows', 'linux', 'macos'], 'arguments': arguments}}}
                with mock.patch.object(sys, 'argv', ['run_flutter_tests.py', *options]), \
                        mock.patch.object(run_flutter_tests, 'load_manifest', return_value=manifest), \
                        mock.patch.object(run_flutter_tests, 'paths', return_value=[]), \
                        mock.patch.object(run_flutter_tests, 'application_tests', return_value=[]), \
                        mock.patch.object(run_flutter_tests, 'select_suite', return_value=['test/declared_test.dart']), \
                        mock.patch.object(run_flutter_tests, 'resolve_flutter', return_value='flutter'), \
                        mock.patch.object(run_flutter_tests, 'run') as execute:
                    with self.assertRaisesRegex(ValueError, 'filters'):
                        run_flutter_tests.main()
                    execute.assert_not_called()


if __name__ == '__main__':
    unittest.main()
