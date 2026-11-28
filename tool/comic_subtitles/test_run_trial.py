import base64
import hashlib
import json
import unittest
import zipfile

from run_trial import SAMPLE, android_report, validate_report


class AndroidTrialReportTests(unittest.TestCase):
    def test_logcat_parts_preserve_long_multilingual_reports(self):
        report = {'error': '原图读取失败\n' * 250, 'rounds': list(range(6))}
        data = base64.b64encode(json.dumps(report, ensure_ascii=False).encode()).decode()
        parts = [f'I flutter : SUBTITLE_TRIAL_PART {i // 480} {data[i:i + 480]}'
                 for i in range(0, len(data), 480)]
        end = f'I flutter : SUBTITLE_TRIAL_END {len(parts)}'
        self.assertIsNone(android_report('\n'.join(parts)))
        self.assertEqual(android_report('\n'.join([*parts, end])), report)
        for incomplete in (parts[:-1], parts[1:], [parts[0], *parts]):
            with self.assertRaises(ValueError):
                android_report('\n'.join([*incomplete, end]))


class TrialAcceptanceTests(unittest.TestCase):
    def setUp(self):
        with zipfile.ZipFile(SAMPLE) as archive:
            hashes = [hashlib.sha256(archive.read(name)).hexdigest()
                      for name in sorted(archive.namelist()) if name.endswith('.png')]
        self.report = {
            'revision': 'fixture', 'passed': True, 'airplaneMode': True,
            'sampleSha256': hashlib.sha256(SAMPLE.read_bytes()).hexdigest(), 'pageSha256': hashes,
            'rounds': [dict(round=index // 2 + 1, enabled=enabled, firstImageUs=16, scrollFrames=3,
                            scrollP95Us=28, peakRssBytes=32, appHttpRequests=0)
                       for index, enabled in enumerate((False, True, True, False, False, True))],
        }

    def test_checks_trial_identity_and_all_six_measurements(self):
        validate_report(self.report, 'fixture', SAMPLE, offline_android=True)
        rounds = self.report['rounds']
        for change in ({'revision': 'other'}, {'passed': False}, {'sampleSha256': ''},
                       {'pageSha256': self.report['pageSha256'][::-1]}, {'rounds': rounds[:-1]},
                       {'rounds': [rounds[1], *rounds[1:]]},
                       {'rounds': [*rounds[:-1], {**rounds[-1], 'scrollFrames': 0}]}):
            with self.subTest(change=list(change)), self.assertRaises(ValueError):
                validate_report({**self.report, **change}, 'fixture', SAMPLE, offline_android=False)

    def test_airplane_mode_and_offline_requests_are_verified(self):
        with self.assertRaisesRegex(ValueError, 'airplane mode'):
            validate_report({**self.report, 'airplaneMode': False}, 'fixture', SAMPLE, offline_android=True)
        self.report['rounds'][-1]['appHttpRequests'] = 1
        with self.assertRaisesRegex(ValueError, 'HTTP'):
            validate_report(self.report, 'fixture', SAMPLE, offline_android=True)
        validate_report(self.report, 'fixture', SAMPLE, offline_android=False)
