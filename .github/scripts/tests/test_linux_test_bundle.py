import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import prepare_linux_test_libraries as libraries


class NativeBundleContractTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        for name in libraries.LIBRARIES:
            (self.directory / name).write_bytes(name.encode())

    def publish(self):
        with patch.object(libraries.ctypes, 'CDLL'), contextlib.redirect_stdout(io.StringIO()):
            libraries.publish_bundle(self.directory)

    def test_fresh_shard_checks_sqlite_and_all_native_library_hashes_before_loading(self):
        self.publish()
        with patch.object(libraries.ctypes, 'CDLL'), contextlib.redirect_stdout(io.StringIO()):
            libraries.verify_bundle(self.directory)
        (self.directory / 'libsqlite3.so').write_bytes(b'modified SQLite library')
        with patch.object(libraries.ctypes, 'CDLL') as load:
            with self.assertRaisesRegex(ValueError, 'hashes do not match'):
                libraries.verify_bundle(self.directory)
            load.assert_not_called()

    def test_missing_library_or_invalid_manifest_cannot_turn_into_a_test_skip(self):
        self.publish()
        path = self.directory / 'libvenera_native.so'
        path.unlink()
        with self.assertRaisesRegex(ValueError, 'Required test library is missing'):
            libraries.verify_bundle(self.directory)
        path.write_bytes(path.name.encode())
        manifest = self.directory / 'libraries.json'
        data = json.loads(manifest.read_text(encoding='utf-8'))
        data['schema_version'] = 99
        manifest.write_text(json.dumps(data), encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'manifest or hashes'):
            libraries.verify_bundle(self.directory)


if __name__ == '__main__':
    unittest.main()
