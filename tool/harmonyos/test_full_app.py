import hashlib
import json
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path

from ci_full_app import ASSET_PREFIX, METADATA_ASSET, audit_full_hap
from prepare_full_app import (EXTRA_LIBRARIES, FULL_CONFIG, ROOT, check_hosted_baseline,
                              configure_pubspec, patch_pdfium_hook, patch_so_loader,
                              patch_sqlite_loader)
from prepare_probe import LIBRARIES


def elf():
    value = bytearray(64)
    value[:6] = b'\x7fELF\x02\x01'
    struct.pack_into('<HH', value, 16, 3, 183)
    return bytes(value)


class FullAppTests(unittest.TestCase):
    def test_overlays_preserve_the_real_application_and_main_version(self):
        original = (ROOT / 'pubspec.yaml').read_text(encoding='utf-8')
        prepared = configure_pubspec(original)
        self.assertIn('name: venera_next\n', prepared)
        self.assertIn('version: 1.18.2-harmony.1+1\n', prepared)
        for name in ('photo_view', 'share_plus', 'rhttp'):
            self.assertIn(f'path: ../../../packages/{name}', prepared)
        self.assertIn('    path: ../full-deps/sqlite3', prepared)
        self.assertIn('    path: ../full-deps/webview/flutter_inappwebview_ohos', prepared)
        self.assertIn('    - assets/init.js', prepared)
        self.assertEqual((ROOT / 'pubspec.yaml').read_text(encoding='utf-8'), original)

    def test_native_loaders_patch_only_the_reviewed_default(self):
        original = 'if (Platform.isAndroid || Platform.isLinux) { return lib; }'
        self.assertIn("Platform.operatingSystem == 'ohos'", patch_so_loader(original))
        self.assertIn("DynamicLibrary.open('libsqlite3.so')", patch_sqlite_loader('DynamicLibrary _defaultOpen() { return linux; }'))
        for value in ('', original + original, patch_so_loader(original)):
            with self.assertRaises(ValueError):
                patch_so_loader(value)

    def test_pdfium_hook_explicitly_leaves_ohos_unsupported(self):
        original = 'if (!input.config.buildCodeAssets) return;\nif (input.config.code.targetOS == OS.iOS) return;'
        result = patch_pdfium_hook(original)
        self.assertIn('targetOS == OS.ohos) return;', result)
        self.assertIn('targetOS == OS.iOS) return;', result)
        with self.assertRaises(ValueError):
            patch_pdfium_hook(result)

    def test_hosted_sources_still_match_the_main_lock(self):
        lock = (ROOT / 'pubspec.lock').read_text(encoding='utf-8')
        for name, spec in FULL_CONFIG['hosted'].items():
            check_hosted_baseline(name, spec, lock)
            with self.assertRaises(ValueError):
                check_hosted_baseline(name, {**spec, 'sha256': '0' * 64}, lock)

    def make_hap(self, root, *, metadata_change=None, app_change=None, omit=None, corrupt_library=False):
        data = elf()
        checksum = hashlib.sha256(data).hexdigest()
        metadata = {'purpose': 'full_reader_experiment', 'reader_integrated': True,
                    'runtime_verified': False, 'signed': False, 'entrypoint': 'lib/main.dart',
                    'bundle_name': FULL_CONFIG['bundle_name'], 'version_name': FULL_CONFIG['version_name'],
                    'hap_version_name': FULL_CONFIG['hap_version_name'],
                    'version_code': FULL_CONFIG['version_code'], 'device_types': ['phone', 'tablet'],
                    'native_libraries': {name: checksum for name in (*LIBRARIES, *EXTRA_LIBRARIES)}}
        packed = {**metadata, **(metadata_change or {})}
        app = {'bundleName': metadata['bundle_name'], 'versionName': metadata['hap_version_name'],
               'versionCode': metadata['version_code'], 'minAPIVersion': 260000026, 'targetAPIVersion': 260000026}
        app.update(app_change or {})
        path = root / 'reader-unsigned.hap'
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('module.json', json.dumps({'app': app, 'module': {'deviceTypes': ['phone', 'tablet']}}))
            archive.writestr(METADATA_ASSET, json.dumps(packed))
            archive.writestr(ASSET_PREFIX + 'assets/init.js', b'real source asset')
            for name in (*LIBRARIES, *EXTRA_LIBRARIES, 'libapp.so', 'libflutter.so'):
                if name != omit:
                    archive.writestr('libs/arm64-v8a/' + name, b'invalid' if corrupt_library else data)
        return path, metadata, {'assets/init.js': hashlib.sha256(b'real source asset').hexdigest()}

    def test_full_reader_packaging_requires_all_real_native_libraries(self):
        with tempfile.TemporaryDirectory() as temporary:
            path, metadata, assets = self.make_hap(Path(temporary))
            result = audit_full_hap(path, metadata, assets)
            self.assertEqual(result['bundle_name'], FULL_CONFIG['bundle_name'])
            self.assertEqual(result['version_name'], FULL_CONFIG['hap_version_name'])
            self.assertEqual(len(result['libraries']), 9)
            for name in EXTRA_LIBRARIES:
                path, metadata, assets = self.make_hap(Path(temporary), omit=name)
                with self.assertRaises(ValueError):
                    audit_full_hap(path, metadata, assets)

    def test_native_numeric_version_is_exact_and_separate_from_dart_prerelease(self):
        self.assertRegex(FULL_CONFIG['hap_version_name'], r'^\d+\.\d+\.\d+\.\d+$')
        self.assertIn('-harmony.', FULL_CONFIG['version_name'])
        with tempfile.TemporaryDirectory() as temporary:
            for name in (FULL_CONFIG['version_name'], '1.18.2.2', '1.18.2'):
                path, metadata, assets = self.make_hap(Path(temporary), app_change={'versionName': name})
                with self.assertRaisesRegex(ValueError, 'versionName'):
                    audit_full_hap(path, metadata, assets)

    def test_audit_rejects_probe_metadata_rewritten_assets_and_bad_elf(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for change in ({'purpose': 'xiaobai_sideload_lab'}, {'runtime_verified': True}, {'signed': True}):
                path, metadata, assets = self.make_hap(root, metadata_change=change)
                with self.assertRaises(ValueError):
                    audit_full_hap(path, metadata, assets)
            path, metadata, assets = self.make_hap(root, corrupt_library=True)
            with self.assertRaises(ValueError):
                audit_full_hap(path, metadata, assets)
            path, metadata, assets = self.make_hap(root)
            with self.assertRaises(ValueError):
                audit_full_hap(path, metadata, {'assets/init.js': '0' * 64})


if __name__ == '__main__':
    unittest.main()
