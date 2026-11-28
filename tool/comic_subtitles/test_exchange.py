import base64
import json
import tempfile
import unittest
import xml.etree.ElementTree as xml
import zipfile
from pathlib import Path

from exchange import TAG, decode, encode, import_revision, pack
from project import ChapterSource, digest


FIXTURES = Path(__file__).resolve().parents[2] / 'spec/comic-subtitles/fixtures'


class ExchangeTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.images = self.root / 'images'
        self.images.mkdir()
        self.image = base64.b64decode(xml.parse(FIXTURES / 'three-pages.acbf').find(f'.//{TAG}binary').text)
        (self.images / 'renamed.png').write_bytes(self.image)
        self.acbf = (FIXTURES / 'editorial.acbf').read_bytes()
        self.manifest = (FIXTURES / 'editorial.pages.json').read_bytes()

    def test_rename_fragments_variants_and_archives(self):
        with ChapterSource(self.images) as source:
            project = decode(self.acbf, self.manifest, source)
        self.assertEqual(project['pages'][0]['image'], 'renamed.png')
        baseline = json.loads(self.manifest)['pages']
        for plain in (False, True):
            target = self.root / f'{plain}.cbz'
            pack(project, target, plain=plain)
            with zipfile.ZipFile(target) as archive:
                self.assertEqual(archive.read('0001.png'), self.image)
                self.assertEqual('book.pages.json' in archive.namelist(), not plain)
            if not plain:
                with ChapterSource(target) as source:
                    adopted = import_revision(source)
                files = encode(adopted)
                self.assertEqual(json.loads(files['book.pages.json'])['pages'], baseline)
                root = xml.fromstring(files['book.acbf'])
                self.assertEqual([ref.get('href') for ref in root.iter(TAG + 'image')], ['0001.png', '0001.png'])
                self.assertEqual([node.text for node in root.iter(TAG + 'p')], ['山の下', 'Mountain ', 'foot', 'Beneath the peak'])

    def test_incompatible_or_inconsistent_revision_gets_rejected(self):
        with ChapterSource(self.images) as source:
            for key, value in [('requires', ['future']), ('acbfSha256', '0' * 64), ('extension', {'opaque': 1})]:
                manifest = {**json.loads(self.manifest), key: value}
                with self.subTest(field=key), self.assertRaises(ValueError):
                    decode(self.acbf, json.dumps(manifest).encode(), source)
            changed = self.acbf.replace(b'Mountain ', b'Mount ')
            manifest = {**json.loads(self.manifest), 'acbfSha256': digest(changed)}
            with self.assertRaisesRegex(ValueError, 'Translated text differs'):
                decode(changed, json.dumps(manifest).encode(), source)
