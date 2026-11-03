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
                              patch_sqlite_loader, patch_webview_native_profile,
                              patch_webview_environment_api)
from prepare_probe import LIBRARIES
from release_context import build_inputs, validate_context, validate_version


def elf():
    value = bytearray(64)
    value[:6] = b'\x7fELF\x02\x01'
    struct.pack_into('<HH', value, 16, 3, 183)
    return bytes(value)


class FullAppTests(unittest.TestCase):
    def test_webview_exit_api_comes_from_the_mainline_pin_without_faking_events(self):
        pin = FULL_CONFIG['webview_api']['revision']
        self.assertEqual(FULL_CONFIG['webview_api']['ref'], pin)
        self.assertIn(f'ref: {pin}', (ROOT / 'pubspec.yaml').read_text(encoding='utf-8'))
        with tempfile.TemporaryDirectory() as temporary:
            destination, upstream = (Path(temporary) / name for name in ('fork', 'upstream'))
            facade = 'flutter_inappwebview/lib/src/webview_environment/webview_environment.dart'
            interface = 'flutter_inappwebview_platform_interface/lib/src/webview_environment/platform_webview_environment.dart'
            types = 'flutter_inappwebview_platform_interface/lib/src/types/'
            fixtures = {
                facade: ('  ///{@macro flutter_inappwebview_platform_interface.PlatformWebViewEnvironment.onBrowserProcessExited}\n'
                         '  set onBrowserProcessExited(void Function(BrowserProcessExitedDetail detail)? value) =>\n'
                         '      platform.onBrowserProcessExited = value;\n'),
                interface: ('  ///{@template flutter_inappwebview_platform_interface.PlatformWebViewEnvironment.onBrowserProcessExited}\n'
                            '  ///Only a real browser exit may complete the owner.\n'
                            '  void Function(BrowserProcessExitedDetail detail)? onBrowserProcessExited;\n'),
            }
            for name, text in fixtures.items():
                path = upstream / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)
                path = destination / name
                path.parent.mkdir(parents=True, exist_ok=True)
                kind = 'macro' if name == facade else 'template'
                path.write_text("import '../types/disposable.dart';\n" +
                                '  ///{@' + kind + ' flutter_inappwebview_platform_interface.PlatformWebViewEnvironment.dispose}\n')
            for name in ('browser_process_exit_kind.dart', 'browser_process_exit_kind.g.dart',
                         'browser_process_exited_detail.dart', 'browser_process_exited_detail.g.dart', 'enum_method.dart'):
                path = upstream / (types + name)
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('original upstream ' + name)
            (destination / types).mkdir(parents=True, exist_ok=True)
            (destination / (types + 'main.dart')).write_text("export 'disposable.dart';\n")
            patch_webview_environment_api(destination, upstream)
            self.assertIn(fixtures[facade].strip(), (destination / facade).read_text())
            self.assertIn(fixtures[interface].strip(), (destination / interface).read_text())
            self.assertEqual((destination / (types + 'browser_process_exited_detail.g.dart')).read_bytes(),
                             (upstream / (types + 'browser_process_exited_detail.g.dart')).read_bytes())
            self.assertIn("export 'browser_process_exited_detail.dart';", (destination / (types + 'main.dart')).read_text())
            with self.assertRaisesRegex(ValueError, 'only be applied once'):
                patch_webview_environment_api(destination, upstream)
            (upstream / facade).write_text('upstream API changed')
            with self.assertRaisesRegex(ValueError, 'API changed'):
                patch_webview_environment_api(destination, upstream)

    def test_overlays_preserve_the_real_application_and_main_version(self):
        original = (ROOT / 'pubspec.yaml').read_text(encoding='utf-8')
        prepared = configure_pubspec(original)
        self.assertIn('name: venera_next\n', prepared)
        identity = build_inputs()
        self.assertIn(f"version: {identity['version_name']}+{identity['version_code']}\n", prepared)
        for name in ('photo_view', 'share_plus', 'rhttp'):
            self.assertIn(f'path: ../../../packages/{name}', prepared)
        self.assertIn('    path: ../full-deps/sqlite3', prepared)
        self.assertIn('    path: ../full-deps/webview/flutter_inappwebview_ohos', prepared)
        self.assertIn('    - assets/init.js', prepared)
        self.assertIn('hooks:\n  user_defines:\n    pdfium_dart:\n      venera_harmonyos_experiment: true', prepared)
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
        self.assertIn("input.userDefines['venera_harmonyos_experiment'] == true) return;", result)
        self.assertIn('targetOS == OS.iOS) return;', result)
        with self.assertRaises(ValueError):
            patch_pdfium_hook(result)

    def test_webview_helper_uses_the_independent_native_build(self):
        original = '''  "buildOption": {
    "externalNativeOptions": {
      "path": "./src/main/cpp/CMakeLists.txt",
      "arguments": "",
      "cppFlags": "",
    }
  },'''
        result = patch_webview_native_profile(original)
        self.assertEqual(result, '  "buildOption": {},')
        with self.assertRaises(ValueError):
            patch_webview_native_profile(result)

    def test_hosted_sources_still_match_the_main_lock(self):
        lock = (ROOT / 'pubspec.lock').read_text(encoding='utf-8')
        for name, spec in FULL_CONFIG['hosted'].items():
            check_hosted_baseline(name, spec, lock)
            with self.assertRaises(ValueError):
                check_hosted_baseline(name, {**spec, 'sha256': '0' * 64}, lock)

    def make_hap(self, root, *, metadata_change=None, app_change=None, omit=None, corrupt_library=False, extra=None):
        data = elf()
        checksum = hashlib.sha256(data).hexdigest()
        identity = build_inputs()
        metadata = {'purpose': 'full_reader_experiment', 'reader_integrated': True,
                    'runtime_verified': False, 'signed': False, 'entrypoint': 'lib/main.dart',
                    'bundle_name': FULL_CONFIG['bundle_name'], 'version_name': identity['version_name'],
                    'hap_version_name': identity['hap_version_name'],
                    'version_code': identity['version_code'], 'device_types': ['phone', 'tablet'],
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
            if extra:
                archive.writestr('libs/arm64-v8a/' + extra, data)
        return path, metadata, {'assets/init.js': hashlib.sha256(b'real source asset').hexdigest()}

    def test_full_reader_packaging_requires_all_real_native_libraries(self):
        with tempfile.TemporaryDirectory() as temporary:
            path, metadata, assets = self.make_hap(Path(temporary))
            result = audit_full_hap(path, metadata, assets)
            self.assertEqual(result['bundle_name'], FULL_CONFIG['bundle_name'])
            self.assertEqual(result['version_name'], build_inputs()['hap_version_name'])
            self.assertEqual(len(result['libraries']), 10)
            for name in EXTRA_LIBRARIES:
                path, metadata, assets = self.make_hap(Path(temporary), omit=name)
                with self.assertRaises(ValueError):
                    audit_full_hap(path, metadata, assets)

    def test_native_numeric_version_is_exact_and_separate_from_dart_prerelease(self):
        self.assertRegex(build_inputs()['hap_version_name'], r'^\d+\.\d+\.\d+$')
        self.assertGreater(build_inputs()['version_code'], 3)
        with tempfile.TemporaryDirectory() as temporary:
            for name in ('1.18.2-harmony.3', '1.18.2.1', '0.0.0'):
                path, metadata, assets = self.make_hap(Path(temporary), app_change={'versionName': name})
                with self.assertRaisesRegex(ValueError, 'versionName'):
                    audit_full_hap(path, metadata, assets)

    def test_caller_version_override_keeps_dependencies_and_original_source(self):
        original = (ROOT / 'pubspec.yaml').read_text(encoding='utf-8')
        prepared = configure_pubspec(original, {'version_name': '1.19.0-rc.1', 'version_code': 244})
        self.assertIn('version: 1.19.0-rc.1+244\n', prepared)
        self.assertIn('archive: ^4.6.0', prepared)
        self.assertEqual((ROOT / 'pubspec.yaml').read_text(encoding='utf-8'), original)

    def test_release_context_is_bound_to_both_commits_run_and_changelog(self):
        context = {'schema': 1, 'channel': 'harmonyos-beta', 'source_commit': '1' * 40,
                   'main_baseline': '2' * 40, 'release_commit': '3' * 40,
                   'version': '1.19.0', 'build': 244, 'tag': 'v1.19.0', 'run_id': '123', 'tagged': True,
                   'changelog': '# Changelog', 'changelog_sha256': hashlib.sha256(b'# Changelog').hexdigest()}
        env = {'GITHUB_SHA': '3' * 40, 'GITHUB_RUN_ID': '123', 'GITHUB_REF_TYPE': 'tag', 'GITHUB_REF_NAME': 'v1.19.0'}
        self.assertEqual(validate_context(context, '1' * 40, env), context)
        for change in ({'source_commit': '4' * 40}, {'release_commit': '4' * 40}, {'run_id': 'other'},
                       {'tag': 'v0.0.0'}, {'changelog': 'tampered'}, {'channel': 'stable'},
                       {'tagged': False}, {'version': '1.19.0-harmony.4'}, {'build': 3}, {'build': True}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                validate_context(context | change, '1' * 40, env)
        for build in (0, 1, 2, 3, True, 2147483648):
            with self.assertRaises(ValueError):
                validate_version('1.19.0', build)

    def test_linux_pdfium_or_other_unreviewed_libraries_are_never_accepted(self):
        with tempfile.TemporaryDirectory() as temporary:
            for name in ('libpdfium.so', 'libother.so'):
                path, metadata, assets = self.make_hap(Path(temporary), extra=name)
                with self.assertRaisesRegex(ValueError, 'Unreviewed/missing'):
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
