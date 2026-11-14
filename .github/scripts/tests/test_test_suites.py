import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import test_suites
from run_flutter_tests import RunReport, resolve_flutter, run


class SuiteOwnershipTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.files = ["test/a_test.dart", "test/features/reader/b_test.dart"]
        for name in self.files:
            self.write(name, "void main() {}")
        self.manifest = {
            "schema_version": 1,
            "suites": {
                "default": {"include": ["test/**/*_test.dart"]},
                "windows": {"include": ["test/a_test.dart"], "source_matches": [r"Platform\.isWindows"]},
            },
            "external": [],
        }

    def write(self, path, text):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")

    def collect(self, **kwargs):
        with patch.object(test_suites, "paths", return_value=self.files):
            return test_suites.collect(self.root, self.manifest, **kwargs)

    def test_recursive_patterns_and_overlaps_preserve_complete_discovery(self):
        self.manifest["suites"]["default"]["include"].append("test/a_test.dart")
        report = self.collect()
        self.assertEqual(report["suite_counts"]["default"], 2)
        self.assertTrue(test_suites.matches("test/root_test.dart", "test/**/*_test.dart"))
        self.assertFalse(test_suites.matches("test/a/b_test.dart", "test/*_test.dart"))

    def test_missing_default_owner_and_stale_paths_fail(self):
        self.manifest["suites"]["default"]["include"] = ["test/a_test.dart"]
        with self.assertRaisesRegex(ValueError, "omits application"):
            self.collect()
        self.manifest["suites"]["default"]["include"] = ["test/deleted_test.dart"]
        with self.assertRaisesRegex(ValueError, "stale or empty"):
            self.collect()

    def test_windows_case_requires_an_actual_windows_owner(self):
        self.write(self.files[1], "void main() { test('native', () {}, skip: !Platform.isWindows); }")
        self.manifest["suites"]["windows"].pop("source_matches")
        with self.assertRaisesRegex(ValueError, "no Windows execution owner"):
            self.collect()

    def test_native_owner_follows_transitive_helpers_and_export_cycles(self):
        self.write(self.files[1], "import '../../support/reader_fixture.dart'; void main() {}")
        self.write("test/support/reader_fixture.dart", "export 'native_fixture.dart';")
        self.write("test/support/native_fixture.dart", "import 'reader_fixture.dart'; import 'native_test_environment.dart';")
        self.write("test/support/native_test_environment.dart", "bool get required => false;")
        self.files.extend(["test/support/reader_fixture.dart", "test/support/native_fixture.dart", "test/support/native_test_environment.dart"])
        self.manifest["suites"]["windows"]["source_matches"] = [r"native_test_environment\.dart"]
        report = self.collect(strict_imports=True)
        self.assertEqual(report["suite_counts"], {"default": 2, "windows": 2})
        self.assertEqual(len(report["helpers"]), 3)

    def test_helper_imports_fail_strict_validation_and_package_entrypoint_is_explicit(self):
        self.write(self.files[0], "import 'features/reader/b_test.dart'; void main() {}")
        with self.assertRaisesRegex(ValueError, "support files"):
            self.collect(strict_imports=True)
        self.manifest["test_entrypoints"] = [{"path": self.files[0], "target": self.files[1], "reason": "Locked package entrypoint"}]
        self.assertTrue(self.collect(strict_imports=True)["test_imports"][0]["entrypoint"])

    def test_unowned_and_ambiguous_external_tests_fail(self):
        external = "tool/bridge/test_state.py"
        self.files.append(external)
        self.write(external, "def test_state():\n    pass\n")
        with self.assertRaisesRegex(ValueError, "Unclassified external"):
            self.collect()
        owner = {"id": "bridge", "include": [external], "kind": "script-behavior", "entry": "python -m unittest"}
        self.manifest["external"] = [owner, {**owner, "id": "duplicate"}]
        with self.assertRaisesRegex(ValueError, "Ambiguous external"):
            self.collect()


def suite(ident, path, timestamp=0):
    return {"type": "suite", "suite": {"id": ident, "path": path}, "time": timestamp}


def start(ident, owner, name, timestamp=0):
    return {"type": "testStart", "test": {"id": ident, "suiteID": owner, "name": name}, "time": timestamp}


def end(ident, timestamp, **extra):
    return {"type": "testDone", "testID": ident, "result": "success", "hidden": False, "skipped": False, "time": timestamp, **extra}


class MachineReportTest(unittest.TestCase):
    @unittest.skipUnless(os.name == "nt", "Windows short temporary-directory aliases")
    def test_windows_short_temp_alias_is_resolved_before_the_child_creates_fixtures(self):
        import ctypes

        with tempfile.TemporaryDirectory(prefix="venera-long-temporary-root-") as directory:
            root = Path(directory).resolve()
            buffer = ctypes.create_unicode_buffer(32768)
            if not ctypes.windll.kernel32.GetShortPathNameW(str(root), buffer, len(buffer)):
                raise ctypes.WinError()
            alias = buffer.value
            if alias.casefold() == str(root).casefold():
                self.skipTest("The temporary volume does not create 8.3 aliases")
            script = (
                "import json,tempfile\n"
                f"assert tempfile.gettempdir().casefold() == {str(root)!r}.casefold()\n"
                + "\n".join("print(" + repr(json.dumps(event)) + ")" for event in [
                    suite(0, "test/a_test.dart"), start(1, 0, "physical fixture root"), end(1, 1),
                    {"type": "done", "success": True, "time": 2},
                ])
            )
            with patch.dict(os.environ, {"TEMP": alias, "TMP": alias, "TMPDIR": alias, "RUNNER_TEMP": alias}), \
                    patch("run_flutter_tests.tempfile.gettempdir", return_value=alias), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(run([sys.executable, "-c", script], root / "report", expected=["test/a_test.dart"]), 0)

    def test_path_launcher_resolves_and_executes_batch_or_shell_entrypoint(self):
        events = [suite(0, "test/a_test.dart"), start(1, 0, "behavior"), end(1, 1),
                  {"type": "done", "success": True, "time": 2}]
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            root = Path(directory)
            launcher = root / ("flutter.bat" if os.name == "nt" else "flutter")
            if os.name == "nt":
                script = "@echo off\n" + "\n".join("echo " + json.dumps(event) for event in events)
            else:
                script = "#!/bin/sh\n" + "\n".join("printf '%s\\n' '" + json.dumps(event) + "'" for event in events)
            launcher.write_text(script + "\n", encoding="utf-8")
            launcher.chmod(0o755)
            with patch.dict(os.environ, {"PATH": str(root)}):
                executable = resolve_flutter("flutter")
                self.assertEqual(Path(executable), launcher)
                self.assertEqual(run([executable], root / "report", expected=["test/a_test.dart"]), 0)
                with self.assertRaises(FileNotFoundError):
                    resolve_flutter("missing-flutter-entrypoint")

    def test_hidden_loading_and_skips_do_not_inflate_passed_cases(self):
        report = RunReport(Path("/repo"))
        for event in [suite(0, "/repo/test/a_test.dart"), start(0, 0, "loading"), end(0, 5, hidden=True),
                      start(1, 0, "behavior", 5), end(1, 15), start(2, 0, "platform", 15),
                      end(2, 15, skipped=True), {"type": "done", "success": True, "time": 16}]:
            report.event(event)
        summary = report.summary()
        self.assertEqual((summary["cases"], summary["passed"], summary["skipped"]), (2, 1, 1))
        self.assertEqual(summary["suites"][0]["path"], "test/a_test.dart")

    def test_concurrent_suite_spans_are_not_summed_as_wall_time(self):
        report = RunReport(Path("/repo"))
        for event in [suite(0, "/repo/test/a_test.dart"), start(0, 0, "a", 5),
                      suite(1, "/repo/test/b_test.dart", 10), start(1, 1, "b", 10),
                      end(0, 65), end(1, 80), {"type": "done", "success": True, "time": 80}]:
            report.event(event)
        summary = report.summary()
        self.assertEqual(summary["elapsed_ms"], 80)
        self.assertEqual([row["suite_span_ms"] for row in summary["suites"]], [70, 65])

    def fake_run(self, events, code=0, expected=None):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            output = Path(directory) / "report"
            script = "\n".join("print(" + repr(json.dumps(event)) + ")" for event in events)
            script += f"\nraise SystemExit({code})"
            result = run([sys.executable, "-c", script], output, expected=expected)
            return result, json.loads((output / "summary.json").read_text(encoding="utf-8"))

    def test_missing_final_event_and_omitted_files_fail_even_with_zero_exit(self):
        result, report = self.fake_run([])
        self.assertNotEqual(result, 0)
        self.assertFalse(report["complete"])
        result, report = self.fake_run([{"type": "done", "success": True}], expected=["test/missing_test.dart"])
        self.assertNotEqual(result, 0)
        self.assertEqual(report["missing_files"], ["test/missing_test.dart"])

    def test_process_and_protocol_failures_are_preserved(self):
        result, _ = self.fake_run([{"type": "done", "success": True}], code=7)
        self.assertEqual(result, 7)
        result, report = self.fake_run([{"type": "testDone", "time": 1}, {"type": "done", "success": True}])
        self.assertNotEqual(result, 0)
        self.assertTrue(report["protocol_errors"])

    def test_successful_exit_cannot_hide_partial_failed_or_unexpected_execution(self):
        valid = [suite(0, 'test/a_test.dart'), start(1, 0, 'behavior'), end(1, 1)]
        terminal = {'type': 'done', 'success': True, 'time': 2}
        scenarios = [
            valid[:-1],
            [suite(0, 'test/a_test.dart'), start(1, 0, 'loading'), end(1, 1, hidden=True)],
            [*valid, suite(2, 'test/foreign_test.dart'), start(3, 2, 'foreign'), end(3, 1)],
            [*valid[:-1], end(1, 1, result='error')],
            [*valid, {'type': 'error', 'error': 'unhandled framework failure', 'time': 1}],
        ]
        for index, events in enumerate(scenarios):
            with self.subTest(index=index):
                result, _ = self.fake_run([*events, terminal], expected=['test/a_test.dart'])
                self.assertNotEqual(result, 0)

    def test_duplicate_terminals_and_unknown_groups_fail_the_protocol(self):
        valid = [suite(0, 'test/a_test.dart'), start(1, 0, 'behavior'), end(1, 1)]
        terminal = {'type': 'done', 'success': True, 'time': 2}
        unknown = start(2, 0, 'unknown group')
        unknown['test']['groupIDs'] = [99]
        for events in [[*valid, end(1, 2), terminal], [*valid, terminal, terminal],
                       [*valid, unknown, end(2, 2), terminal]]:
            with self.subTest(events=events):
                result, _ = self.fake_run(events, expected=['test/a_test.dart'])
                self.assertNotEqual(result, 0)

    def test_requested_coverage_cannot_reuse_a_stale_report(self):
        events = [suite(0, 'test/a_test.dart'), start(1, 0, 'behavior'), end(1, 1),
                  {'type': 'done', 'success': True, 'time': 2}]
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            root = Path(directory)
            coverage = root / 'lcov.info'
            coverage.write_text('old coverage', encoding='utf-8')
            script = '\n'.join('print(' + repr(json.dumps(event)) + ')' for event in events)
            result = run([sys.executable, '-c', script], root / 'report', expected=['test/a_test.dart'],
                         coverage_path=coverage)
            self.assertNotEqual(result, 0)
            self.assertFalse(coverage.exists())


if __name__ == "__main__":
    unittest.main()
