import copy
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
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
        write(self.root, release.PIN, json.dumps(self.pin))
        self.set_version('1.18.3', 244)

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
        return release.context(self.root, self.source, self.environment(tagged=tagged))

    def bundle(self, *, metadata_change=None, members_change=None, report_change=None):
        expected = self.context()
        names = release.asset_names(expected['version'])
        source_files = {
            name: release.sha256(release.blob(self.source, self.source_commit, name))
            for name in release.tracked(self.source, self.source_commit)
            if name in {'pubspec.yaml', 'pubspec.lock', 'CHANGELOG.md'}
            or name.startswith('assets/') or (name.startswith('lib/') and name.endswith('.dart'))
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
            'native_libraries': {name: release.sha256(native) for name in release.NATIVE},
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
            **{'libs/arm64-v8a/' + name: bytes(native) for name in release.NATIVE | {'libapp.so', 'libflutter.so'}},
        }
        expected_assets = {name: release.sha256(members[release.ASSETS + name])
                           for name in ('assets/page.txt', 'pubspec.yaml', 'CHANGELOG.md')}
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
        self.fixture.set_version('1.19.0-rc.2', 245)
        expected = self.fixture.bundle()
        self.assertEqual(expected['version'], '1.19.0-rc.2')
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
        self.assertIn('outputs/harmonyos/*', workflow)
        self.assertIn('--verify-tag', workflow)
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


if __name__ == '__main__':
    unittest.main()
