import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import warnings
import zipfile


ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location('harmonyos_release', ROOT / '.github/scripts/harmonyos_release.py')
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


def git(root, *args):
    return subprocess.check_output(
        ['git', '-C', str(root), '-c', 'core.autocrlf=false', '-c', 'commit.gpgsign=false',
         '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', *args],
        stderr=subprocess.PIPE, timeout=30,
    ).decode().strip()


def write(root, name, value):
    target = root / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(value if isinstance(value, bytes) else value.encode())


def commit(root):
    git(root, 'add', '--all')
    git(root, 'commit', '-m', 'test(ci): fixture')
    return git(root, 'rev-parse', 'HEAD')


class Fixture:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.source = self.directory / 'source'
        self.root = self.directory / 'release'
        self.output = self.directory / 'artifacts'
        self.source.mkdir()
        git(self.source, 'init', '--initial-branch=main')
        self.pubspec = ('name: venera_next\nversion: 1.18.2+243\n'
                        'dependencies:\n  archive: ^4.6.0\nflutter:\n  assets:\n'
                        '    - assets/page.txt\n')
        for name, content in {
            '.gitignore': 'build/\n',
            'pubspec.yaml': self.pubspec,
            'pubspec.lock': 'locked dependencies\n',
            'release.json': json.dumps({'version': '1.18.2', 'build': 243}),
            'CHANGELOG.md': '# Changes\n\n## v1.18.2\n\nEarlier version.\n',
            'lib/main.dart': 'void main() {}\n',
            'assets/page.txt': 'original asset',
        }.items():
            write(self.source, name, content)
        self.baseline = commit(self.source)
        git(self.directory, 'clone', '--no-hardlinks', str(self.source), str(self.root))
        for name, content in {
            'lib/harmony.dart': 'const beta = true;\n',
            'doc/distribution/harmonyos-reader.zh.md': '# Guide\n[harmonyos-reader.en.md](harmonyos-reader.en.md)\n',
            'doc/distribution/harmonyos-reader.en.md': '# Guide\n[harmonyos-reader.zh.md](harmonyos-reader.zh.md)\n',
        }.items():
            write(self.source, name, content)
        self.source_commit = commit(self.source)
        self.pin = {'schema': 1, 'source_commit': self.source_commit,
                    'main_baseline': self.baseline, 'first_release_build': 244}
        self.preview_next = False
        write(self.root, release.PIN, json.dumps(self.pin))
        self.set_version('1.18.3', 244)

    def next_candidate(self):
        self.next_baseline = self.release_commit
        git(self.source, 'fetch', str(self.root), 'HEAD')
        git(self.source, 'merge', '--no-ff', '-m', 'test(ci): merge baseline', 'FETCH_HEAD')
        for name, content in {
            'release.json': json.dumps({'version': '1.18.3', 'build': 245}),
            'pubspec.yaml': self.pubspec.replace('1.18.2+243', '1.18.3+245'),
            'CHANGELOG.md': '# Changes\n\n## v1.18.3\n\nNext candidate notes.\n',
            'packages/venera_native/pubspec.yaml': 'name: venera_native\nversion: 1.0.0\n',
            'packages/venera_native/LICENSE': 'project license\n',
            release.NOTICE_SOURCE: 'reviewed official codec notice\n',
            'doc/development/git_dependencies.json': json.dumps({'local_packages': [
                {'dependency': 'venera_native', 'path': 'packages/venera_native', 'version': '1.0.0'}]}),
            'tool/harmonyos/toolchain.json': json.dumps({'quickjs': {'revision': 'a' * 40}}),
            'tool/harmonyos/full_app_config.json': json.dumps({
                'project_packages': ['venera_native'],
                **{name: {'revision': 'b' * 40} for name in ('webview', 'webview_api', 'code_assets')},
                'hosted': {'sqlite3': {'version': '2.7.4', 'sha256': 'c' * 64}}}),
        }.items():
            write(self.source, name, content)
        self.source_commit = commit(self.source)
        self.next_pin = {'schema': 2, 'source_commit': self.source_commit,
                         'main_baseline': self.next_baseline, 'first_release_build': 245, 'release_enabled': False}
        write(self.root, release.NEXT_PIN, json.dumps(self.next_pin))
        self.release_commit = commit(self.root)
        self.preview_next = True

    def unified_mainline(self, *, release_enabled=False):
        self.next_candidate()
        for name in release.tracked(self.source, self.source_commit):
            write(self.root, name, release.blob(self.source, self.source_commit, name))
        self.next_pin = {'schema': 3, 'source_mode': 'release_commit',
                         'first_release_build': 245, 'release_enabled': release_enabled}
        write(self.root, release.NEXT_PIN, json.dumps(self.next_pin))
        self.release_commit = commit(self.root)
        self.sync_mainline_source()

    def sync_mainline_source(self):
        git(self.source, 'fetch', str(self.root), 'HEAD')
        git(self.source, 'checkout', '--detach', 'FETCH_HEAD')
        self.source_commit = git(self.source, 'rev-parse', 'HEAD')

    def set_version(self, version, build):
        write(self.root, 'release.json', json.dumps({'version': version, 'build': build}))
        write(self.root, 'pubspec.yaml', self.pubspec.replace('1.18.2+243', f'{version}+{build}'))
        write(self.root, 'CHANGELOG.md', f'# Changes\n\n## v{version}\n\nRelease notes.\n')
        self.release_commit = commit(self.root)

    def environment(self, *, tagged=False):
        config = json.loads((self.root / 'release.json').read_text())
        return {'GITHUB_SHA': git(self.root, 'rev-parse', 'HEAD'), 'GITHUB_RUN_ID': '12345',
                'GITHUB_REF_TYPE': 'tag' if tagged else 'branch',
                'GITHUB_REF_NAME': 'v' + str(config['version']) if tagged else 'main'}

    def context(self, *, tagged=False):
        return release.context(self.root, self.source, self.environment(tagged=tagged), preview_next=self.preview_next)

    def bundle(self, *, tagged=False, metadata_change=None, members_change=None, report_change=None):
        expected = self.context(tagged=tagged)
        next_candidate = expected['schema'] >= 2
        native_names = release.NEXT_NATIVE if next_candidate else release.NATIVE
        names = release.asset_names(expected['version'])
        source_files = {
            name: release.sha256(release.blob(self.source, self.source_commit, name))
            for name in release.tracked(self.source, self.source_commit)
            if name in {'pubspec.yaml', 'pubspec.lock', 'CHANGELOG.md'}
            or name.startswith('assets/') or (name.startswith('lib/') and name.endswith('.dart'))
            or (next_candidate and (name == 'release.json' or name.startswith('packages/')))
        }
        native = bytearray(64)
        native[:6] = b'\x7fELF\x02\x01'
        struct.pack_into('<HH', native, 16, 3, 183)
        metadata = {
            'purpose': 'full_reader_experiment', 'entrypoint': 'lib/main.dart',
            'signed': False, 'runtime_verified': False, 'reader_integrated': True,
            'source_commit': self.source_commit, 'release': release.public_context(expected),
            'source_files': source_files, 'bundle_name': release.BUNDLE,
            'version_name': expected['version'], 'hap_version_name': expected['version'].split('-')[0],
            'version_code': expected['build'], 'bundled_assets': {'assets/page.txt': source_files['assets/page.txt']},
            'native_libraries': {name: release.sha256(native) for name in native_names},
        }
        if next_candidate:
            metadata['bundled_assets'][release.NOTICE] = source_files[release.NOTICE_SOURCE]
            metadata['dependencies'] = {
                'venera_native': {'project_path': 'packages/venera_native', 'version': '1.0.0',
                                  'prepared_sha256': release.package_digest(
                                      self.source, self.source_commit, 'packages/venera_native',
                                      release.tracked(self.source, self.source_commit))},
                'flutter_qjs': {'revision': 'a' * 40, 'prepared_sha256': 'd' * 64},
                **{name: {'revision': 'b' * 40, 'prepared_sha256': 'e' * 64}
                   for name in ('webview', 'webview_api', 'code_assets')},
                'sqlite3': {'version': '2.7.4', 'sha256': 'c' * 64, 'prepared_sha256': 'f' * 64},
            }
        if metadata_change:
            metadata_change(metadata)
        app = {'bundleName': release.BUNDLE, 'versionName': expected['version'].split('-')[0],
               'versionCode': expected['build'], 'minAPIVersion': 260000026, 'targetAPIVersion': 260000026}
        pubspec = self.pubspec.replace('1.18.2+243', f"{expected['version']}+{expected['build']}").encode()
        members = {
            'module.json': json.dumps({'app': app, 'module': {'deviceTypes': ['phone', 'tablet']}}).encode(),
            release.METADATA: json.dumps(metadata).encode(),
            release.ASSETS + 'assets/page.txt': b'original asset',
            release.ASSETS + 'pubspec.yaml': pubspec,
            release.ASSETS + 'CHANGELOG.md': expected['changelog'].encode(),
            **{'libs/arm64-v8a/' + name: bytes(native) for name in native_names | {'libapp.so', 'libflutter.so'}},
        }
        if next_candidate:
            members[release.ASSETS + release.NOTICE] = release.blob(self.source, self.source_commit, release.NOTICE_SOURCE)
        expected_assets = {name: release.sha256(members[release.ASSETS + name])
                           for name in ('assets/page.txt', 'pubspec.yaml', 'CHANGELOG.md',
                                        *((release.NOTICE,) if next_candidate else ()))}
        if members_change:
            members_change(members)
        self.output.mkdir(exist_ok=True)
        with zipfile.ZipFile(self.output / names['hap'], 'w') as archive:
            for name, data in members.items():
                archive.writestr(name, data)
        report = {'status': 'packaging_pass', 'signed': False, 'runtime_verified': False,
                  'reader_integrated': True, 'commit': self.source_commit, 'hap': names['hap'],
                  'build': metadata, 'expected_assets': expected_assets}
        if report_change:
            report_change(report)
        write(self.output, names['manifest'], json.dumps(report))
        self.refresh_package_digest(expected)
        for language in ('zh', 'en'):
            text = release.blob(self.source, self.source_commit, f'doc/distribution/harmonyos-reader.{language}.md').decode()
            for companion in ('zh', 'en'):
                text = text.replace(f'harmonyos-reader.{companion}.md', f'harmonyos-install.{companion}.md')
            write(self.output, names[language], text)
        return expected

    def refresh_package_digest(self, expected):
        names = release.asset_names(expected['version'])
        hap = self.output / names['hap']
        report = json.loads((self.output / names['manifest']).read_text())
        report.update(bytes=hap.stat().st_size, sha256=release.sha256(hap.read_bytes()))
        write(self.output, names['manifest'], json.dumps(report))
        write(self.output, names['checksums'], f"{report['sha256']}  {hap.name}\n")


class HarmonyReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='harmony-release-test-')
        self.addCleanup(temporary.cleanup)
        self.fixture = Fixture(temporary.name)

    def verify(self, expected):
        return release.verify_bundle(self.fixture.output, expected, self.fixture.source)

    def test_release_only_changes_preserve_a_common_immutable_baseline(self):
        fixture = self.fixture
        context = fixture.context()
        self.assertEqual(context['source_commit'], fixture.source_commit)
        self.assertEqual(context['main_baseline'], fixture.baseline)
        self.assertEqual(context['release_commit'], fixture.release_commit)
        self.assertEqual(context['build'], 244)
        self.assertFalse(context['tagged'])
        self.assertNotIn('changelog', release.public_context(context))
        self.assertIn('changelog_sha256', release.public_context(context))

    def test_pin_schema_full_sha_and_first_build_are_required(self):
        fixture = self.fixture
        for change in ({'schema': True}, {'schema': 2}, {'source_commit': 'HarmonyOS'},
                       {'source_commit': 'a' * 39}, {'main_baseline': 'main'},
                       {'first_release_build': 243}, {'first_release_build': True}, {'extra': 1}):
            with self.subTest(change=change):
                write(fixture.root, release.PIN, json.dumps(fixture.pin | change))
                with self.assertRaises(ValueError):
                    release.load_pin(fixture.root)

    def test_wrong_source_and_baseline_cannot_be_used(self):
        fixture = self.fixture
        with self.assertRaisesRegex(ValueError, 'pinned commit'):
            release.check_sources(fixture.root, fixture.source, fixture.pin | {'source_commit': fixture.baseline})
        with self.assertRaisesRegex(ValueError, 'reviewed main baseline'):
            release.check_sources(fixture.root, fixture.source, fixture.pin | {'main_baseline': fixture.source_commit})

    def test_dirty_and_untracked_source_inputs_are_rejected(self):
        fixture = self.fixture
        write(fixture.source, 'lib/injected.dart', 'void injected() {}')
        with self.assertRaisesRegex(ValueError, 'untracked inputs'):
            fixture.context()
        (fixture.source / 'lib/injected.dart').unlink()
        write(fixture.source, 'lib/main.dart', 'void changed() {}')
        with self.assertRaisesRegex(ValueError, 'uncommitted changes'):
            fixture.context()

    def test_dirty_caller_is_rejected_but_ignored_build_evidence_is_not_source(self):
        fixture = self.fixture
        write(fixture.source, 'build/evidence.txt', 'local evidence')
        self.assertEqual(fixture.context()['build'], 244)
        write(fixture.root, 'CHANGELOG.md', 'uncommitted caller changes')
        with self.assertRaisesRegex(ValueError, 'uncommitted changes'):
            fixture.context()

    def test_runtime_and_dependency_drift_require_a_new_reviewed_baseline(self):
        fixture = self.fixture
        for name, text in [('lib/main.dart', 'void changed() {}'),
                           ('pubspec.lock', 'changed lock'),
                           ('rust-toolchain.toml', '[toolchain]\nchannel="new"')]:
            write(fixture.root, name, text)
            commit(fixture.root)
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, 'stale files'):
                fixture.context()

    def test_pubspec_dependency_changes_are_not_version_only_changes(self):
        fixture = self.fixture
        path = fixture.root / 'pubspec.yaml'
        path.write_text(path.read_text().replace('archive: ^4.6.0', 'archive: ^5.0.0'))
        commit(fixture.root)
        with self.assertRaisesRegex(ValueError, 'stale files: pubspec.yaml'):
            fixture.context()

    def test_tag_build_uses_the_actual_tag_target_and_first_supported_build(self):
        fixture = self.fixture
        git(fixture.root, 'tag', '-a', 'v1.18.3', '-m', 'fixture')
        self.assertTrue(fixture.context(tagged=True)['tagged'])
        fixture.set_version('1.18.2', 243)
        with self.assertRaisesRegex(ValueError, 'predates HAP distribution'):
            fixture.context(tagged=True)

    def test_wrong_tag_target_and_wrong_caller_commit_are_rejected(self):
        fixture = self.fixture
        git(fixture.root, 'tag', '-a', 'v1.18.3', fixture.baseline, '-m', 'fixture')
        with self.assertRaisesRegex(ValueError, 'tag does not identify'):
            fixture.context(tagged=True)
        with self.assertRaisesRegex(ValueError, "caller.s exact release commit"):
            release.context(fixture.root, fixture.source, fixture.environment() | {'GITHUB_SHA': fixture.baseline})

    def test_invalid_versions_builds_and_missing_changelog_fail(self):
        fixture = self.fixture
        for version, build in [('1.18.3-harmony.4', 244), ('1.18.3', True), ('1.18.3', 3), ('1.18.3', 2147483648)]:
            fixture.set_version(version, build)
            with self.subTest(version=version, build=build), self.assertRaisesRegex(ValueError, 'Invalid release version'):
                fixture.context()
        fixture.set_version('1.18.3', 244)
        write(fixture.root, 'CHANGELOG.md', '# Changes\n\n## Unreleased\n')
        commit(fixture.root)
        with self.assertRaisesRegex(ValueError, 'Missing release changelog'):
            fixture.context()

    def test_real_git_inventory_and_all_five_synthetic_assets_are_checked(self):
        expected = self.fixture.bundle()
        assets = self.verify(expected)
        self.assertEqual(set(assets), set(release.asset_names(expected['version']).values()))
        self.assertTrue(all(item['bytes'] > 0 for item in assets.values()))

    def test_rc_dart_version_has_a_separate_numeric_native_version(self):
        self.fixture.next_candidate()
        self.fixture.preview_next = False
        self.fixture.set_version('1.19.0-rc.2', 245)
        expected = self.fixture.bundle()
        self.assertEqual(expected['version'], '1.19.0-rc.2')
        self.verify(expected)

    def test_next_preview_keeps_244_pin_bytes_and_uses_the_candidates_own_245_metadata(self):
        fixture = self.fixture
        frozen = (fixture.root / release.PIN).read_bytes()
        fixture.next_candidate()
        expected = fixture.bundle()
        assets = self.verify(expected)
        self.assertEqual((fixture.root / release.PIN).read_bytes(), frozen)
        self.assertEqual(release.select_pin(fixture.root), fixture.pin)
        self.assertEqual(release.select_pin(fixture.root, preview_next=True), fixture.next_pin)
        self.assertEqual((expected['build'], expected['caller_build']), (245, 244))
        self.assertEqual(expected['schema'], 2)
        self.assertTrue(expected['preview'])
        self.assertIn('Next candidate notes.', expected['changelog'])
        with self.assertRaisesRegex(ValueError, 'preview assets cannot be published'):
            release.check_remote_release({}, expected, assets, published=False)
        with self.assertRaisesRegex(ValueError, 'tag cannot use'):
            fixture.context(tagged=True)

    def test_245_releases_select_next_and_never_fall_back_to_the_frozen_source(self):
        fixture = self.fixture
        fixture.set_version('1.19.0', 245)
        with self.assertRaises(FileNotFoundError):
            fixture.context()
        fixture.next_candidate()
        fixture.preview_next = False
        self.assertEqual(release.select_pin(fixture.root), fixture.next_pin)
        context = fixture.context()
        self.assertFalse(context['preview'])
        self.assertEqual((context['build'], context['caller_build']), (245, 245))
        with self.assertRaisesRegex(ValueError, 'verified release-tag context'):
            release.check_remote_release({}, context, {}, published=False)

    def test_next_pin_requires_complete_sha_and_a_build_above_244(self):
        fixture = self.fixture
        fixture.next_candidate()
        for change in ({'first_release_build': 244}, {'first_release_build': True},
                       {'source_commit': 'HarmonyOS'}, {'main_baseline': 'main'}, {'extra': 1},
                       {'schema': 1}, {'release_enabled': 0}):
            with self.subTest(change=change):
                write(fixture.root, release.NEXT_PIN, json.dumps(fixture.next_pin | change))
                with self.assertRaises(ValueError):
                    release.load_pin(fixture.root, next_candidate=True)

    def test_next_tags_require_explicit_release_readiness_after_source_review(self):
        fixture = self.fixture
        fixture.next_candidate()
        fixture.preview_next = False
        fixture.set_version('1.19.0', 245)
        git(fixture.root, 'tag', '-a', 'v1.19.0', '-m', 'fixture')
        with self.assertRaisesRegex(ValueError, 'preview only'):
            fixture.context(tagged=True)
        # A separately reviewed pin must explicitly enable distribution; a
        # passing preview by itself never turns the candidate into a release.
        fixture.next_pin['release_enabled'] = True
        write(fixture.root, release.NEXT_PIN, json.dumps(fixture.next_pin))
        fixture.release_commit = commit(fixture.root)
        git(fixture.root, 'tag', '-d', 'v1.19.0')
        git(fixture.root, 'tag', '-a', 'v1.19.0', '-m', 'reviewed fixture')
        self.assertTrue(fixture.context(tagged=True)['tagged'])

    def test_mainline_preview_binds_both_checkouts_and_all_assets_to_one_commit(self):
        fixture = self.fixture
        frozen = (fixture.root / release.PIN).read_bytes()
        fixture.unified_mainline()
        expected = fixture.bundle()
        self.assertEqual(len(self.verify(expected)), 5)
        self.assertEqual(expected['schema'], 3)
        self.assertEqual(expected['source_mode'], 'release_commit')
        self.assertEqual(expected['source_commit'], expected['release_commit'])
        self.assertEqual((expected['build'], expected['caller_build']), (245, 245))
        self.assertNotIn('main_baseline', expected)
        self.assertEqual((fixture.root / release.PIN).read_bytes(), frozen)
        self.assertEqual(release.selected_source_commit(fixture.root, fixture.next_pin), fixture.release_commit)
        with self.assertRaisesRegex(ValueError, 'preview'):
            release.check_remote_release({}, expected, {}, published=False)

    def test_mainline_fix_needs_no_pin_edit_but_rejects_an_older_source_checkout(self):
        fixture = self.fixture
        fixture.unified_mainline()
        config = (fixture.root / release.NEXT_PIN).read_bytes()
        write(fixture.root, 'lib/main.dart', 'void main() { print("fixed"); }\n')
        fixture.release_commit = commit(fixture.root)
        with self.assertRaisesRegex(ValueError, 'pinned commit'):
            fixture.context()
        fixture.sync_mainline_source()
        expected = fixture.bundle()
        self.verify(expected)
        self.assertEqual(expected['source_commit'], fixture.release_commit)
        self.assertEqual((fixture.root / release.NEXT_PIN).read_bytes(), config)

    def test_mainline_mode_rejects_branch_names_and_embedded_source_pins(self):
        fixture = self.fixture
        fixture.unified_mainline()
        for change in ({'source_mode': 'main'}, {'source_mode': 'HarmonyOS'},
                       {'source_commit': fixture.source_commit}, {'main_baseline': fixture.baseline},
                       {'first_release_build': 244}, {'first_release_build': True},
                       {'release_enabled': 1}, {'schema': True}):
            with self.subTest(change=change):
                write(fixture.root, release.NEXT_PIN, json.dumps(fixture.next_pin | change))
                with self.assertRaises(ValueError):
                    release.load_pin(fixture.root, next_candidate=True)

    def test_mainline_context_rejects_untracked_caller_and_staged_source_drift(self):
        fixture = self.fixture
        fixture.unified_mainline()
        write(fixture.root, 'lib/injected.dart', 'void injected() {}')
        with self.assertRaisesRegex(ValueError, 'untracked inputs'):
            fixture.context()
        (fixture.root / 'lib/injected.dart').unlink()
        write(fixture.source, 'lib/main.dart', 'void changed() {}')
        git(fixture.source, 'add', 'lib/main.dart')
        with self.assertRaisesRegex(ValueError, 'uncommitted changes'):
            fixture.context()

    def test_mainline_tag_stays_disabled_until_explicit_acceptance(self):
        fixture = self.fixture
        fixture.unified_mainline()
        fixture.preview_next = False
        git(fixture.root, 'tag', '-a', 'v1.18.3', '-m', 'fixture')
        with self.assertRaisesRegex(ValueError, 'preview only'):
            fixture.context(tagged=True)

    def test_enabled_mainline_tag_uses_the_same_commit_and_rejects_wrong_action_sha(self):
        fixture = self.fixture
        fixture.unified_mainline(release_enabled=True)
        fixture.preview_next = False
        git(fixture.root, 'tag', '-a', 'v1.18.3', '-m', 'fixture')
        expected = fixture.context(tagged=True)
        self.assertTrue(expected['tagged'])
        self.assertEqual(expected['source_commit'], expected['release_commit'])
        environment = fixture.environment(tagged=True) | {'GITHUB_SHA': fixture.baseline}
        with self.assertRaisesRegex(ValueError, 'exact release commit'):
            release.context(fixture.root, fixture.source, environment)

    def test_metadata_gate_blocks_disabled_tags_before_emitting_build_outputs(self):
        fixture = self.fixture
        fixture.unified_mainline()
        output = fixture.directory / 'github-output.txt'
        arguments = ['harmonyos_release.py', 'config', '--root', str(fixture.root),
                     '--github-output', str(output)]
        for version, build in (('1.18.3-rc.1', 246), ('1.18.3', 247)):
            fixture.set_version(version, build)
            with self.subTest(version=version), patch.dict(os.environ, fixture.environment(tagged=True)), \
                    patch.object(sys, 'argv', arguments), self.assertRaisesRegex(ValueError, 'preview only'):
                release.main()
            self.assertFalse(output.exists())
        with patch.dict(os.environ, fixture.environment()), patch.object(sys, 'argv', arguments), \
                contextlib.redirect_stdout(io.StringIO()):
            release.main()
        self.assertIn('source_commit=' + fixture.release_commit, output.read_text())

    def test_prerelease_and_stable_haps_bind_full_versions_and_increasing_builds(self):
        fixture = self.fixture
        fixture.unified_mainline(release_enabled=True)
        fixture.preview_next = False
        frozen = (fixture.root / release.PIN).read_bytes()
        policy = (fixture.root / release.NEXT_PIN).read_bytes()
        for version, build in (('1.18.3-rc.1', 246), ('1.18.3', 247)):
            fixture.set_version(version, build)
            fixture.sync_mainline_source()
            git(fixture.root, 'tag', '-a', 'v' + version, '-m', 'reviewed release')
            fixture.output = fixture.directory / f'artifacts-{build}'
            expected = fixture.bundle(tagged=True)
            assets = self.verify(expected)
            with self.subTest(version=version):
                self.assertEqual(expected['source_commit'], fixture.release_commit)
                self.assertEqual(expected['release_commit'], fixture.release_commit)
                self.assertEqual((expected['version'], expected['build']), (version, build))
                self.assertFalse(expected['preview'])
                self.assertEqual(len(assets), 5)
                remote = {'tag_name': 'v' + version, 'draft': True, 'prerelease': '-rc.' in version,
                          'assets': [{'name': name, 'size': item['bytes'],
                                      'digest': 'sha256:' + item['sha256'], 'state': 'uploaded'}
                                     for name, item in assets.items()]}
                release.check_remote_release(remote, expected, assets, published=False)
                release.check_remote_release(remote | {'draft': False}, expected, assets, published=True)
                with self.assertRaisesRegex(ValueError, 'release tag/state/channel'):
                    release.check_remote_release(remote | {'prerelease': not remote['prerelease']},
                                                 expected, assets, published=False)
            self.assertEqual((fixture.root / release.PIN).read_bytes(), frozen)
            self.assertEqual((fixture.root / release.NEXT_PIN).read_bytes(), policy)

    def test_other_platform_assets_never_allow_omitting_a_harmonyos_companion(self):
        fixture = self.fixture
        fixture.unified_mainline(release_enabled=True)
        fixture.preview_next = False
        git(fixture.root, 'tag', '-a', 'v1.18.3', '-m', 'reviewed release')
        expected = fixture.bundle(tagged=True)
        assets = self.verify(expected)
        remote = {'tag_name': expected['tag'], 'draft': True, 'prerelease': False,
                  'assets': [{'name': name, 'size': item['bytes'],
                              'digest': 'sha256:' + item['sha256'], 'state': 'uploaded'}
                             for name, item in assets.items()] +
                            [{'name': 'VeneraNext-1.18.3-' + name, 'state': 'uploaded'}
                             for name in ('android.apk', 'android-tv.apk', 'windows.zip',
                                          'macos.dmg', 'ios.ipa', 'linux.AppImage')]}
        release.check_remote_release(remote, expected, assets, published=False)
        for name in assets:
            damaged = copy.deepcopy(remote)
            damaged['assets'] = [item for item in damaged['assets'] if item['name'] != name]
            with self.subTest(asset=name), self.assertRaisesRegex(ValueError, 'HarmonyOS release assets'):
                release.check_remote_release(damaged, expected, assets, published=False)

    def test_tagged_ci_staging_keeps_notes_outputs_and_both_checkouts_separate(self):
        fixture = self.fixture
        fixture.unified_mainline(release_enabled=True)
        fixture.preview_next = False
        git(fixture.root, 'tag', '-a', 'v1.18.3', '-m', 'reviewed release')
        write(fixture.root, 'release_notes.md', 'generated release notes')
        with self.assertRaisesRegex(ValueError, 'untracked inputs'):
            fixture.context(tagged=True)
        (fixture.root / 'release_notes.md').unlink()
        write(fixture.directory, 'release_notes.md', 'generated release notes')
        fixture.output = fixture.directory / 'outputs/harmonyos'
        fixture.output.parent.mkdir()
        expected = fixture.bundle(tagged=True)
        assets = self.verify(expected)
        self.assertEqual(len(assets), 5)
        self.assertFalse(git(fixture.root, 'ls-files', '--others', '--exclude-standard'))
        self.assertFalse(git(fixture.source, 'ls-files', '--others', '--exclude-standard'))

    def test_mainline_bundle_still_rejects_rewritten_project_code_and_native_libraries(self):
        fixture = self.fixture
        fixture.unified_mainline()
        for mutate in (lambda m: m['source_files'].update({'lib/main.dart': '0' * 64}),
                       lambda m: m['dependencies']['venera_native'].update(prepared_sha256='0' * 64),
                       lambda m: m['native_libraries'].pop('libvenera_native.so')):
            with self.subTest(mutate=mutate):
                expected = fixture.bundle(metadata_change=mutate)
                with self.assertRaises(ValueError):
                    self.verify(expected)

    def test_next_preview_still_rejects_unsynced_application_source(self):
        fixture = self.fixture
        fixture.next_candidate()
        write(fixture.root, 'lib/main.dart', 'void changed() {}\n')
        commit(fixture.root)
        with self.assertRaisesRegex(ValueError, 'stale files: lib/main.dart'):
            fixture.context()

    def test_an_untracked_next_pin_cannot_supply_release_provenance(self):
        fixture = self.fixture
        fixture.next_candidate()
        git(fixture.root, 'rm', '--cached', release.NEXT_PIN)
        git(fixture.root, 'commit', '-m', 'test(ci): remove committed pin')
        with self.assertRaisesRegex(ValueError, 'committed inputs'):
            fixture.context()

    def test_next_inventory_native_set_and_generated_notice_cannot_be_omitted_or_forged(self):
        self.fixture.next_candidate()
        for change in (
            lambda m: m['source_files'].pop(release.NOTICE_SOURCE),
            lambda m: m['source_files'].pop('release.json'),
            lambda m: m['dependencies'].pop('venera_native'),
            lambda m: m['dependencies']['venera_native'].update(prepared_sha256='0' * 64),
            lambda m: m['dependencies']['webview'].update(revision='0' * 40),
            lambda m: m['dependencies']['sqlite3'].update(sha256='0' * 64),
            lambda m: m['bundled_assets'].pop(release.NOTICE),
            lambda m: m['native_libraries'].update({'liblodepng_flutter.so': '0' * 64}),
        ):
            expected = self.fixture.bundle(metadata_change=change)
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.verify(expected)
        for change in (
            lambda m: m.pop(release.ASSETS + release.NOTICE),
            lambda m: m.update({release.ASSETS + release.NOTICE: b'altered notice'}),
            lambda m: m.update({'libs/arm64-v8a/libflutter_7zip.so': b'old wrapper'}),
        ):
            expected = self.fixture.bundle(members_change=change)
            with self.subTest(change=change), self.assertRaises((ValueError, KeyError)):
                self.verify(expected)

    def test_missing_extra_and_modified_companion_assets_are_rejected(self):
        fixture = self.fixture
        expected = fixture.bundle()
        write(fixture.output, 'extra.hap', b'unreviewed')
        with self.assertRaisesRegex(ValueError, 'unexpected HarmonyOS release assets'):
            self.verify(expected)
        (fixture.output / 'extra.hap').unlink()
        names = release.asset_names(expected['version'])
        for companion in ('manifest', 'checksums', 'zh', 'en'):
            fixture.bundle()
            (fixture.output / names[companion]).unlink()
            with self.subTest(companion=companion), self.assertRaisesRegex(ValueError, 'Missing or unexpected'):
                self.verify(expected)
        fixture.bundle()
        write(fixture.output, names['zh'], 'wrong guide')
        with self.assertRaisesRegex(ValueError, 'guide differs'):
            self.verify(expected)

    def test_forged_source_run_and_runtime_claims_are_rejected(self):
        for change in (
            lambda m: m.update(runtime_verified=True),
            lambda m: m.update(signed=True),
            lambda m: m['release'].update(run_id='another-run'),
            lambda m: m['source_files'].update({'lib/main.dart': '0' * 64}),
            lambda m: m['source_files'].pop('lib/main.dart'),
            lambda m: m['native_libraries'].pop('libqjs.so'),
        ):
            expected = self.fixture.bundle(metadata_change=change)
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.verify(expected)

    def test_real_module_native_payload_and_embedded_assets_are_checked(self):
        def wrong_module(members):
            module = json.loads(members['module.json'])
            module['app']['versionCode'] = 3
            members['module.json'] = json.dumps(module).encode()

        for change in (
            wrong_module,
            lambda m: m.update({'libs/arm64-v8a/libqjs.so': b'not an ELF'}),
            lambda m: m.update({'libs/x86_64/libqjs.so': b'wrong architecture'}),
            lambda m: m.update({release.ASSETS + 'assets/page.txt': b'altered asset'}),
            lambda m: m.update({release.ASSETS + 'CHANGELOG.md': b'wrong release notes'}),
            lambda m: m.update({release.ASSETS + 'pubspec.yaml': b'version: 1.18.2+3\n'}),
            lambda m: m.update({'../outside': b'unsafe'}),
        ):
            expected = self.fixture.bundle(members_change=change)
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.verify(expected)

    def test_duplicate_and_crc_corrupt_hap_members_fail_even_with_new_outer_digest(self):
        fixture = self.fixture
        expected = fixture.bundle()
        hap = fixture.output / release.asset_names(expected['version'])['hap']
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            with zipfile.ZipFile(hap, 'a') as archive:
                archive.writestr('module.json', b'{}')
        fixture.refresh_package_digest(expected)
        with self.assertRaisesRegex(ValueError, 'Duplicated or corrupt'):
            self.verify(expected)
        fixture.bundle()
        with zipfile.ZipFile(hap) as archive:
            entry = archive.getinfo(release.ASSETS + 'assets/page.txt')
        data = bytearray(hap.read_bytes())
        name_size, extra_size = struct.unpack_from('<HH', data, entry.header_offset + 26)
        data[entry.header_offset + 30 + name_size + extra_size] ^= 1
        hap.write_bytes(data)
        fixture.refresh_package_digest(expected)
        with self.assertRaisesRegex(ValueError, 'Duplicated or corrupt'):
            self.verify(expected)

    def test_uploaded_assets_must_match_sizes_digests_and_state_before_publication(self):
        expected = self.fixture.bundle()
        assets = self.verify(expected)
        remote = {'tag_name': expected['tag'], 'draft': True, 'prerelease': False,
                  'assets': [{'name': name, 'size': item['bytes'], 'digest': 'sha256:' + item['sha256'], 'state': 'uploaded'}
                             for name, item in assets.items()]}
        release.check_remote_release(remote, expected, assets, published=False)
        release.check_remote_release(remote | {'draft': False}, expected, assets, published=True)
        mutations = [
            lambda r: r.update(draft=False), lambda r: r.pop('draft'), lambda r: r.update(prerelease=True),
            lambda r: r.update(prerelease=0),
            lambda r: r['assets'].pop(), lambda r: r['assets'].append(r['assets'][0]),
            lambda r: r['assets'].append({'name': 'unreviewed.hap'}),
            lambda r: r['assets'][0].update(state='starter'),
            lambda r: r['assets'][0].update(size=0), lambda r: r['assets'][0].pop('digest'),
            lambda r: r['assets'][0].update(digest='sha256:' + '0' * 64),
        ]
        for mutate in mutations:
            damaged = copy.deepcopy(remote)
            mutate(damaged)
            with self.subTest(mutate=mutate), self.assertRaises(ValueError):
                release.check_remote_release(damaged, expected, assets, published=False)

    def test_workflow_requires_hap_and_draft_verification_before_publishing(self):
        workflow = (ROOT / '.github/workflows/main.yml').read_text(encoding='utf-8')
        self.assertIn('needs: [Release_Metadata, Quality, Build, HarmonyOS]', workflow)
        harmony_job = workflow.split('\n  HarmonyOS:\n', 1)[1].split('\n  Release:\n', 1)[0]
        self.assertIn('needs: [Release_Metadata, Quality]', harmony_job)
        self.assertIn('uses: ./.github/workflows/harmonyos-release.yml', harmony_job)
        self.assertNotRegex(harmony_job, r'(?m)^    (?:if|continue-on-error):')
        self.assertIn('outputs/harmonyos/*', workflow)
        publish_job = workflow.split('\n  Release:\n', 1)[1]
        self.assertIn('working-directory: release-source', publish_job)
        self.assertIn('path: release-source', publish_job)
        self.assertIn('path: harmonyos-source', publish_job)
        self.assertIn('--write-notes ../release_notes.md', publish_job)
        self.assertIn('--source-root ../harmonyos-source --artifacts ../outputs/harmonyos', publish_job)
        self.assertIn('verify-release --directory ../outputs', publish_job)
        self.assertIn('--notes-file ../release_notes.md', publish_job)
        self.assertIn('--verify-tag', workflow)
        self.assertIn('--target "${GITHUB_SHA}"', publish_job)
        self.assertLess(workflow.index('verify-draft'), workflow.index('--draft=false'))
        self.assertGreater(workflow.index('verify-published'), workflow.index('--draft=false'))
        hap = (ROOT / '.github/workflows/harmonyos-release.yml').read_text(encoding='utf-8')
        self.assertIn('ref: ${{ steps.pin.outputs.source_commit }}', hap)
        self.assertIn('fetch-depth: 0', hap)
        self.assertIn('if-no-files-found: error', hap)
        self.assertNotIn('continue-on-error', hap)
        self.assertNotIn('contents: write', hap)
        self.assertNotIn('secrets: inherit', hap)
        self.assertNotIn('gh issue', workflow + hap)


class HarmonyRemoteReleaseTests(unittest.TestCase):
    def setUp(self):
        self.expected = {'schema': 3, 'version': '1.18.3-rc.3', 'tag': 'v1.18.3-rc.3',
                         'preview': False, 'tagged': True}
        self.assets = {name: {'bytes': 2, 'sha256': 'd' * 64}
                       for name in release.asset_names(self.expected['version']).values()}
        self.remote = {'id': 123, 'tag_name': self.expected['tag'], 'draft': True, 'prerelease': True,
                       'assets': [{'name': name, 'size': record['bytes'],
                                   'digest': 'sha256:' + record['sha256'], 'state': 'uploaded'}
                                  for name, record in self.assets.items()]}

    def test_draft_cli_succeeds_when_published_tag_endpoint_returns_404(self):
        def github(*args):
            endpoint = args[-1]
            if endpoint == f"repos/{release.REPOSITORY}/releases/tags/{self.expected['tag']}":
                raise subprocess.CalledProcessError(1, ['gh', *args], stderr=b'Not Found (HTTP 404)')
            if endpoint == f'repos/{release.REPOSITORY}/releases?per_page=100':
                return json.dumps([[{'id': 99, 'tag_name': 'v1.18.2', 'draft': False}], [self.remote]])
            if endpoint == f"repos/{release.REPOSITORY}/releases/{self.remote['id']}":
                return json.dumps(self.remote)
            self.fail(f'Unexpected GitHub API request: {args!r}')

        argv = ['harmonyos_release.py', 'verify-draft', '--source-root', str(ROOT),
                '--artifacts', str(ROOT / 'build/remote-release-regression')]
        with patch.object(sys, 'argv', argv), patch.object(release, 'context', return_value=self.expected), \
                patch.object(release, 'verify_bundle', return_value=self.assets), \
                patch.object(release, 'gh', side_effect=github), contextlib.redirect_stdout(io.StringIO()):
            release.main()

    def test_draft_lookup_rejects_missing_duplicate_and_malformed_candidates(self):
        for pages in (
            [], [[]], [[self.remote], [self.remote]],
            [[self.remote | {'draft': False}]], [[self.remote | {'draft': 1}]],
            [[self.remote | {'id': 0}]], [[self.remote | {'id': True}]],
            [[self.remote | {'id': '../other'}]], [[None]], {'releases': [self.remote]},
        ):
            with self.subTest(pages=pages), patch.object(release, 'gh', return_value=json.dumps(pages)) as github, \
                    self.assertRaises(ValueError):
                release.read_remote_release(self.expected['tag'], published=False)
            self.assertEqual(github.call_count, 1)

    def test_draft_lookup_rejects_changed_id_tag_or_state_after_listing(self):
        for remote in (
            self.remote | {'id': 124}, self.remote | {'id': True},
            self.remote | {'tag_name': 'v1.18.2'}, self.remote | {'draft': False},
            self.remote | {'draft': 1}, [],
        ):
            with self.subTest(remote=remote), \
                    patch.object(release, 'gh', side_effect=[json.dumps([[self.remote]]), json.dumps(remote)]), \
                    self.assertRaisesRegex(ValueError, 'identity changed'):
                release.read_remote_release(self.expected['tag'], published=False)

    def test_published_lookup_uses_public_tag_endpoint(self):
        remote = self.remote | {'draft': False}
        with patch.object(release, 'gh', return_value=json.dumps(remote)) as github:
            self.assertEqual(release.read_remote_release(self.expected['tag'], published=True), remote)
        github.assert_called_once_with('api', f"repos/{release.REPOSITORY}/releases/tags/{self.expected['tag']}")


if __name__ == '__main__':
    unittest.main()
