from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import run_android_jvm_tests as jvm


class JvmEntrypointTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.files = [
            'test/native/SessionTest.kt',
            'android/app/src/main/kotlin/app/Session.kt',
            'packages/share_plus/android/src/test/kotlin/share/OwnershipTest.kt',
            'packages/share_plus/android/src/main/kotlin/share/Session.kt',
        ]
        for path in self.files:
            self.write(path, '// fixture')
        self.write('android/settings.gradle', 'id "org.jetbrains.kotlin.android" version "2.1.0"')
        self.write('packages/share_plus/android/build.gradle', "ext.kotlin_version = '2.2.0'")
        self.manifest = {'external': [
            {'id': 'android-jvm', 'include': ['test/native/*.kt'], 'jvm_groups': [
                {'test': self.files[0], 'sources': [self.files[1]], 'main': 'app.SessionTest'}]},
            {'id': 'share-android', 'include': ['packages/share_plus/android/src/test/**/*.kt'], 'jvm_groups': [
                {'test': self.files[2], 'sources': [self.files[3]], 'main': 'share.OwnershipTest'}]},
        ]}

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding='utf-8')

    def groups(self):
        with patch.object(jvm, 'paths', return_value=self.files):
            return jvm.owned_groups(self.manifest, root=self.root)

    def test_both_compiler_profiles_own_and_compile_their_production_sources(self):
        owners = self.groups()
        self.assertEqual({owner['id'] for owner in owners}, {'android-jvm', 'share-android'})

    def test_added_or_duplicate_test_main_cannot_silently_escape_execution(self):
        self.files.append('test/native/NewTest.kt')
        with self.assertRaisesRegex(ValueError, 'Unowned, duplicate or stale'):
            self.groups()
        self.files.pop()
        self.manifest['external'][0]['jvm_groups'] *= 2
        with self.assertRaisesRegex(ValueError, 'Unowned, duplicate or stale'):
            self.groups()

    def test_missing_production_source_or_main_fails(self):
        group = self.manifest['external'][0]['jvm_groups'][0]
        group['sources'] = ['android/app/src/main/kotlin/app/Deleted.kt']
        with self.assertRaisesRegex(ValueError, 'Missing production'):
            self.groups()
        group['sources'] = [self.files[1]]
        group['main'] = ''
        with self.assertRaisesRegex(ValueError, 'run their main'):
            self.groups()

    def test_each_profile_rejects_drift_from_its_package_declaration(self):
        for path, changed in [
            ('android/settings.gradle', 'id "org.jetbrains.kotlin.android" version "2.2.0"'),
            ('packages/share_plus/android/build.gradle', "ext.kotlin_version = '2.1.0'"),
        ]:
            original = (self.root / path).read_text(encoding='utf-8')
            self.write(path, changed)
            with self.assertRaisesRegex(ValueError, 'must match'):
                self.groups()
            self.write(path, original)
        self.manifest['external'].pop()
        with self.assertRaisesRegex(ValueError, 'Every JVM owner'):
            self.groups()

    def test_cached_compiler_is_checksum_verified_before_execution(self):
        directory = self.root / 'compiler'
        self.write('compiler/compiler.zip', 'modified archive')
        self.write('compiler/kotlinc/bin/kotlinc', 'executable still exists')
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            jvm.compiler(directory)

    def test_real_runtime_and_compiler_output_reject_wrong_versions(self):
        self.assertEqual(jvm.java_version('openjdk version "17.0.18"'), 17)
        self.assertEqual(jvm.compiler_version('info: kotlinc-jvm 2.2.0 (JRE 17.0.18+8)', '2.2.0'), '2.2.0')
        for text in ['java version "21.0.1"', 'no java runtime']:
            with self.assertRaisesRegex(ValueError, 'actual Java 17'):
                jvm.java_version(text)
        for text in ['info: kotlinc-jvm 2.1.0 (JRE 17.0.18+8)',
                     'info: kotlinc-jvm 2.2.0 (JRE 21.0.1+1)']:
            with self.assertRaisesRegex(ValueError, 'compiler must be'):
                jvm.compiler_version(text, '2.2.0')


if __name__ == '__main__':
    unittest.main()
