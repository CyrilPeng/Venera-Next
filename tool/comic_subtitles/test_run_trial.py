import base64
import json
import unittest

from run_trial import android_report


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
