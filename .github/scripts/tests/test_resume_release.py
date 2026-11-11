import contextlib
import copy
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import resume_release as resume


def build_run():
    return {'id': 123, 'event': 'push', 'path': '.github/workflows/main.yml',
            'head_sha': 'a' * 40, 'head_branch': 'v1.18.4-rc.1',
            'status': 'completed', 'conclusion': 'failure',
            'repository': {'full_name': resume.release.REPOSITORY}}


def passed_jobs():
    return [{'name': name, 'status': 'completed', 'conclusion': 'success'}
            for name in sorted(resume.REQUIRED_JOBS)] + [
        {'name': 'Release', 'status': 'completed', 'conclusion': 'failure'},
        {'name': 'Build / Manual_Quality', 'status': 'completed', 'conclusion': 'skipped'}]


def git(root, *args):
    return subprocess.check_output(
        ['git', '-C', str(root), '-c', 'user.name=Fixture',
         '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false',
         '-c', 'core.autocrlf=false', *args], stderr=subprocess.PIPE, timeout=30).decode().strip()


class RecoverySourceTests(unittest.TestCase):
    def test_only_completed_same_repository_tag_builds_are_eligible(self):
        run = build_run()
        self.assertEqual(resume.validate_build_run(run, passed_jobs(), 123), run)
        for change in ({'id': 124}, {'event': 'workflow_dispatch'}, {'event': 'pull_request'},
                       {'head_branch': 'main'}, {'head_branch': 'v1.18.4\n'},
                       {'head_sha': 'short'}, {'path': '.github/workflows/build.yml'},
                       {'status': 'in_progress'}, {'conclusion': 'cancelled'},
                       {'repository': {'full_name': 'other/repository'}}, {'repository': None}):
            with self.subTest(change=change), self.assertRaisesRegex(ValueError, 'completed tagged'):
                resume.validate_build_run(run | change, passed_jobs(), 123)

    def test_missing_failed_skipped_duplicate_or_running_required_jobs_block_recovery(self):
        jobs = passed_jobs()
        for name in resume.REQUIRED_JOBS:
            for conclusion in ('failure', 'cancelled', 'skipped', None):
                changed = [job | {'conclusion': conclusion} if job['name'] == name else job for job in jobs]
                with self.subTest(name=name, conclusion=conclusion), self.assertRaisesRegex(ValueError, 'gate did not pass'):
                    resume.validate_build_run(build_run(), changed, 123)
        for changed in (jobs[1:], jobs + [jobs[0]], [jobs[0] | {'status': 'in_progress'}, *jobs[1:]]):
            with self.assertRaises(ValueError):
                resume.validate_build_run(build_run(), changed, 123)
        with self.assertRaisesRegex(ValueError, 'Only a failed publishing job'):
            resume.validate_build_run(build_run(), jobs + [
                {'name': 'Another gate', 'status': 'completed', 'conclusion': 'failure'}], 123)

    def test_tooling_changes_cannot_hide_runtime_version_staged_or_untracked_changes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            git(root, 'init', '-q')
            for name in ('CHANGELOG.md', 'pubspec.yaml', 'main.dart'):
                (root / name).write_text('original\n')
            git(root, 'add', '.')
            git(root, 'commit', '-qm', 'fixture')
            run = build_run() | {'head_sha': git(root, 'rev-parse', 'HEAD')}
            (root / 'CHANGELOG.md').write_text('Tooling repair\n')
            git(root, 'add', '.')
            git(root, 'commit', '-qm', 'tooling')
            def api(*args):
                return json.dumps([{'jobs': passed_jobs()[:8]}, {'jobs': passed_jobs()[8:]}]
                                  if '/jobs?' in args[-1] else run)
            with patch.object(resume.release, 'gh', side_effect=api):
                self.assertEqual(resume.original_build(root, 123), (run, git(root, 'rev-parse', 'HEAD')))
                for name in ('main.dart', 'pubspec.yaml'):
                    (root / name).write_text('uncommitted change\n')
                    git(root, 'add', name)
                    with self.assertRaisesRegex(ValueError, 'uncommitted'):
                        resume.original_build(root, 123)
                    git(root, 'commit', '-qm', 'runtime drift')
                    with self.assertRaisesRegex(ValueError, 'must not change runtime'):
                        resume.original_build(root, 123)
                    (root / name).write_text('original\n')
                    git(root, 'add', name)
                    git(root, 'commit', '-qm', 'restore fixture')
                (root / 'untracked.dart').write_text('unexpected source\n')
                with self.assertRaisesRegex(ValueError, 'untracked'):
                    resume.original_build(root, 123)


class RecoveryArtifactTests(unittest.TestCase):
    def populate(self, root):
        for name in resume.RELEASE_ARTIFACTS:
            directory = root / name
            directory.mkdir(parents=True)
            (directory / (name + '.bin')).write_bytes(name.encode())

    def test_collection_keeps_hap_separate_and_ignores_diagnostic_packages(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.populate(root / 'downloaded')
            diagnostic = root / 'downloaded/android-saf-provider-evidence'
            diagnostic.mkdir()
            (diagnostic / 'probe.apk').write_bytes(b'Not a release package')
            resume.collect_artifacts(root / 'downloaded', root / 'outputs')
            self.assertFalse((root / 'outputs/probe.apk').exists())
            self.assertEqual((root / 'outputs/harmonyos/harmonyos-release.bin').read_bytes(), b'harmonyos-release')
            self.assertEqual(len(list((root / 'outputs').rglob('*.bin'))), len(resume.RELEASE_ARTIFACTS))

    def test_missing_empty_and_duplicate_artifacts_cannot_be_published(self):
        for mode in ('missing', 'empty', 'duplicate'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self.populate(root / 'downloaded')
                directory = root / 'downloaded/windows_build'
                if mode in ('missing', 'empty'):
                    (directory / 'windows_build.bin').unlink()
                    if mode == 'missing':
                        directory.rmdir()
                else:
                    (directory / 'ios_build.bin').write_bytes(b'Conflicting name')
                with self.assertRaisesRegex(ValueError, 'Missing|Empty|Duplicate'):
                    resume.collect_artifacts(root / 'downloaded', root / 'outputs')


class RecoveryPublicationTests(unittest.TestCase):
    def exercise(self, *, ready=True, failure=None):
        with tempfile.TemporaryDirectory() as temporary, contextlib.ExitStack() as stack:
            root = Path(temporary)
            packages = root / 'outputs'
            hap = packages / 'harmonyos'
            hap.mkdir(parents=True)
            package = packages / 'linux~rc.deb'
            package.write_bytes(b'Original compiler bytes')
            notes, receipt = root / 'notes.md', root / 'receipt.json'
            notes.write_text('Original tag notes\n')
            expected = {'schema': 3, 'tagged': True, 'preview': False, 'release_commit': 'a' * 40,
                        'source_commit': 'a' * 40, 'tag': 'v1.18.4-rc.1', 'version': '1.18.4-rc.1',
                        'runtime_acceptance': 'stable_required'}
            records = resume.release.release_file_records([package])
            remote = {'id': 456, 'tag_name': expected['tag'], 'target_commitish': 'a' * 40,
                      'draft': True, 'prerelease': True, 'body': 'Original tag notes\r\n',
                      'assets': [{'name': 'linux.rc.deb', 'size': package.stat().st_size, 'state': 'uploaded',
                                  'digest': 'sha256:' + records[package.name]['sha256']}]}
            published = copy.deepcopy(remote) | {'draft': False, 'html_url': 'https://example.invalid/release'}
            if failure == 'notes':
                remote['body'] = 'Unexpected notes'
            elif failure == 'source':
                remote['target_commitish'] = 'b' * 40
            elif failure == 'digest':
                remote['assets'][0]['digest'] = 'sha256:' + '0' * 64
            elif failure == 'published_digest':
                published['assets'][0]['digest'] = 'sha256:' + '0' * 64
            argv = ['resume_release.py', 'publish', '--run', '123', '--source-root', str(root),
                    '--artifacts', str(hap), '--notes-file', str(notes),
                    '--release-files', str(package), '--receipt', str(receipt)]
            stack.enter_context(patch.object(sys, 'argv', argv))
            stack.enter_context(patch.dict(os.environ, {'GITHUB_RUN_ID': '999', 'GITHUB_SHA': 'b' * 40}))
            stack.enter_context(patch.object(resume, 'original_build', return_value=(build_run(), 'c' * 40)))
            context = stack.enter_context(patch.object(resume.release, 'context', return_value=expected))
            stack.enter_context(patch.object(resume.release, 'verify_bundle', return_value={}))
            stack.enter_context(patch.object(resume.release, 'read_remote_release', side_effect=[remote, published]))
            stack.enter_context(patch.object(resume.release, 'blob', return_value=b'version: 1.18.4-rc.1+250'))
            android = stack.enter_context(patch.object(resume.android, 'verify_release'))
            runtime = stack.enter_context(patch.object(resume.release, 'check_runtime', return_value=ready))
            github = stack.enter_context(patch.object(resume.release, 'gh'))
            if failure == 'android':
                android.side_effect = ValueError('Invalid original Android catalog')
            if failure == 'runtime':
                runtime.side_effect = ValueError('Failed device acceptance report')
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            if failure:
                with self.assertRaises(ValueError):
                    resume.main()
                self.assertFalse(receipt.exists())
                if failure != 'published_digest':
                    github.assert_not_called()
                return
            resume.main()
            value = json.loads(receipt.read_text())
            self.assertEqual(value['original_run'], 123)
            self.assertEqual(value['recovery_run'], '999')
            self.assertEqual(value['source_commit'], 'a' * 40)
            self.assertEqual(value['published'], ready)
            self.assertEqual(value['files'], records)
            self.assertEqual(value['github_files']['linux.rc.deb'], records['linux~rc.deb'])
            self.assertEqual(context.call_args.args[2], resume.original_environment(build_run()))
            self.assertEqual(android.call_args.args[2]['GITHUB_SHA'], 'a' * 40)
            if ready:
                github.assert_called_once_with('release', 'edit', 'v1.18.4-rc.1', '--repo',
                                               resume.release.REPOSITORY, '--draft=false', '--latest=false')
                self.assertEqual(runtime.call_count, 2)
            else:
                github.assert_not_called()

    def test_publish_binds_original_run_preserves_packages_and_does_not_advance_stable(self):
        self.exercise()

    def test_missing_required_acceptance_retains_the_draft(self):
        self.exercise(ready=False)

    def test_source_notes_assets_android_and_runtime_failures_stop_publication(self):
        for failure in ('notes', 'source', 'digest', 'android', 'runtime', 'published_digest'):
            with self.subTest(failure=failure):
                self.exercise(failure=failure)


if __name__ == '__main__':
    unittest.main()
