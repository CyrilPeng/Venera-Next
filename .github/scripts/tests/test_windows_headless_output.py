"""Check the CLI smoke oracle without launching an app or touching its profile."""
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "test_windows_startup.ps1"
PWSH = shutil.which("pwsh")


@unittest.skipUnless(PWSH, "PowerShell is required for the Windows CLI oracle")
class HeadlessOutputTests(unittest.TestCase):
    def check_output(self, content, message='WebDAV sync is not configured.', status='error'):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "stdout.log"
            log.write_text(content, encoding="utf-8")
            # Parse the script, extracting only its output assertion function.
            # Never execute the installer, process launcher or profile setup.
            command = r"""
$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($args[0], [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw 'Invalid smoke script syntax' }
$function = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Assert-HeadlessOutput'
}, $true)
if ($null -eq $function) { throw 'Output assertion missing' }
. ([scriptblock]::Create($function.Extent.Text))
Assert-HeadlessOutput $args[1] $args[2] $args[3]
"""
            runner = Path(directory) / "oracle.ps1"
            runner.write_text(command, encoding="utf-8")
            return subprocess.run(
                [PWSH, "-NoProfile", "-File", str(runner), str(SCRIPT), str(log), message, status],
                capture_output=True, text=True, encoding="utf-8", timeout=20,
            )

    def test_accepts_expected_final_json_with_engine_noise(self):
        result = self.check_output('engine diagnostic\n[CLI PRINT] ' + json.dumps({
            'status': 'error', 'message': 'WebDAV sync is not configured.',
        }) + '\n')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_no_protocol_output(self):
        self.assertNotEqual(self.check_output('engine crashed\n').returncode, 0)

    def test_rejects_malformed_json(self):
        self.assertNotEqual(self.check_output('[CLI PRINT] {invalid}\n').returncode, 0)

    def test_rejects_later_wrong_terminal_result(self):
        prefix = '[CLI PRINT] '
        good = {'status': 'error', 'message': 'WebDAV sync is not configured.'}
        wrong = {'status': 'error', 'message': 'Core initialization failed'}
        content = prefix + json.dumps(good) + '\n' + prefix + json.dumps(wrong) + '\n'
        self.assertNotEqual(self.check_output(content).returncode, 0)

    def test_rejects_success_with_matching_message(self):
        result = self.check_output('[CLI PRINT] ' + json.dumps({
            'status': 'success', 'message': 'WebDAV sync is not configured.',
        }) + '\n')
        self.assertNotEqual(result.returncode, 0)

    def test_accepts_success_for_empty_default_tracking_folder(self):
        result = self.check_output('[CLI PRINT] ' + json.dumps({
            'status': 'success', 'message': 'Updated comics list.', 'data': [],
        }) + '\n', 'Updated comics list.', 'success')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_subscription_error_when_success_is_expected(self):
        result = self.check_output('[CLI PRINT] ' + json.dumps({
            'status': 'error', 'message': 'Updated comics list.', 'data': [],
        }) + '\n', 'Updated comics list.', 'success')
        self.assertNotEqual(result.returncode, 0)
