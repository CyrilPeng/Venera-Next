import importlib.util
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('windows_build', ROOT / 'windows/build.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class WindowsBuildTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name, value in [('ROOT', self.root), ('WINDOWS_BUILD_DIR', self.root / 'build/windows')]:
            patcher = patch.object(build, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_archive_contains_full_bundle_and_keeps_architectures_separate(self):
        for arch in ('x64', 'arm64'):
            runner, suffix, _ = build.architecture_paths(arch)
            release = runner / 'Release'
            (release / 'data').mkdir(parents=True)
            (release / 'VeneraNext.exe').write_bytes(arch.encode())
            (release / 'data/plugin.dll').write_bytes(b'plugin')
            path = build.create_portable_zip('1.2.3', arch)
            with zipfile.ZipFile(path) as archive:
                prefix = f'VeneraNext-1.2.3-{suffix}/'
                self.assertEqual(archive.read(prefix + 'VeneraNext.exe'), arch.encode())
                self.assertEqual(archive.read(prefix + 'data/plugin.dll'), b'plugin')
            self.assertFalse(path.with_suffix('').exists())
            self.assertTrue(release.exists())

    def test_build_failure_does_not_package_stale_outputs(self):
        with patch.object(build, 'read_version', return_value='1.2.3'), patch.object(build, 'validate_icon_resources'), patch.object(build, 'clean_windows_runner_build'), patch.object(build, 'run', side_effect=RuntimeError('build failed')), patch.object(build, 'create_portable_zip') as package:
            with self.assertRaisesRegex(RuntimeError, 'build failed'):
                build.main('arm64')
            package.assert_not_called()

    def test_installer_failure_restores_exact_template_bytes(self):
        for arch in ('x64', 'arm64'):
            _, _, template = build.architecture_paths(arch)
            template.parent.mkdir(parents=True, exist_ok=True)
            original = b'{{version}}\r\n{{root_path}}\r\n'
            template.write_bytes(original)
            with patch.object(build, 'ensure_chinese_translation'), patch.object(build, 'run', side_effect=RuntimeError('compiler failed')):
                with self.assertRaisesRegex(RuntimeError, 'compiler failed'):
                    build.build_installer('1.2.3', arch)
            self.assertEqual(template.read_bytes(), original)

    def test_rejects_external_cleanup_and_unknown_architecture(self):
        with self.assertRaises(ValueError):
            build.remove_build_directory(self.root)
        with self.assertRaises(ValueError):
            build.architecture_paths('../external')
        self.assertTrue(self.root.exists())

    def test_version_rejects_path_traversal(self):
        (self.root / 'pubspec.yaml').write_text('version: ../../outside+1\n')
        with self.assertRaises(ValueError):
            build.read_version()

    def test_checked_command_runs_from_repository_root(self):
        with patch.object(build.shutil, 'which', return_value='flutter.bat'), patch.object(build.subprocess, 'run') as run:
            build.run(['flutter', 'build', 'windows'])
            run.assert_called_once_with(['flutter.bat', 'build', 'windows'], check=True, cwd=self.root)


if __name__ == '__main__':
    unittest.main()
