import io
import json
import tempfile
import unittest
import xml.etree.ElementTree as xml
import zipfile
from pathlib import Path
from unittest import mock

from PIL import Image

from exchange import TAG, publish
from project import (ChapterSource, apply_edit, atomic_json, create_project, digest, page_at,
                     read_json, recognize, recognize_candidate, verified_image)


class AuthorTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.folder = self.root / 'pages'
        self.folder.mkdir()
        for name in ('10.png', '2.png'):
            Image.new('RGB', (80, 100), 'white').save(self.folder / name)
        self.source = self.enter_source(self.folder)
        self.project = create_project(self.source, 'ja')
        self.page = page_at(self.project, 1)

    def enter_source(self, path):
        source = ChapterSource(path).__enter__()
        self.addCleanup(source.__exit__, None, None, None)
        return source

    @staticmethod
    def engine(image):
        return [[[[[1, 2], [8, 2], [8, 30], [1, 30]], '山', .86],
                 [[[12, 3], [35, 3], [35, 15], [12, 15]], '下', .97]], None]

    def test_source_identity_order_and_orientation(self):
        self.assertEqual(self.source.names, ['2.png', '10.png'])
        buf = io.BytesIO()
        exif = Image.Exif()
        exif[274] = 6
        Image.new('RGB', (32, 16)).save(buf, 'JPEG', exif=exif)
        cbz = self.root / 'images.cbz'
        with zipfile.ZipFile(cbz, 'w') as archive:
            archive.writestr('chapter/image.jpg', buf.getvalue())
        source = self.enter_source(cbz)
        page = create_project(source, 'zh')['pages'][0]
        self.assertEqual(page['size'], [16, 32])
        self.assertEqual(page['sha256'], digest(buf.getvalue()))
        with verified_image(source, page) as image:
            self.assertEqual(image.size, (16, 32))

    def test_failure_retry_empty_and_checkpoint(self):
        recognize(self.page, self.source, mock.Mock(side_effect=RuntimeError('decoder failed')), 'fixture')
        self.assertEqual(self.page['status'], 'failed')
        dest = self.root / 'book.json'
        atomic_json(dest, self.project)
        saved = read_json(dest)
        self.assertEqual(saved['pages'][1]['status'], 'pending')
        recognize(saved['pages'][0], self.source, lambda _: (None, None), 'fixture')
        self.assertEqual(saved['pages'][0]['status'], 'empty')
        with mock.patch('project.os.replace', side_effect=OSError), self.assertRaises(OSError):
            atomic_json(dest, saved)
        self.assertEqual(read_json(dest), self.project)
        (self.folder / '2.png').write_bytes(b'changed')
        recognize(self.page, self.source, self.engine, 'fixture')
        self.assertIn('changed', self.page['error'])

    def test_edits_preserve_raw_ids_and_lineage(self):
        recognize(self.page, self.source, self.engine, 'fixture')
        first, second = self.page['dialogues']
        self.assertEqual(first['direction'], 'vertical-rl')
        apply_edit(self.page, dict(op='edit', id=first['id'], text='山の'))
        self.assertEqual(first['revision'], 2)
        self.assertEqual(self.page['observations'][0]['text'], '山')
        apply_edit(self.page, dict(op='order', ids=[second['id'], first['id']]))
        apply_edit(self.page, dict(op='merge', ids=[first['id'], second['id']]))
        merged, = self.page['dialogues']
        self.assertEqual((merged['text'], merged['area']), ('山の下', [1, 2, 35, 30]))
        apply_edit(self.page, dict(op='split', id=merged['id'], parts=[dict(text='山の', area=first['area']),
                                                                      dict(text='下', area=second['area'])]))
        self.assertEqual(self.page['lineage'][1]['old'][0]['id'], merged['id'])
        self.assertEqual(self.page['lineage'][1]['new'], [item['id'] for item in self.page['dialogues']])
        self.assertEqual(len(self.page['observations']), 2)

    def test_recognition_rerun_only_changes_the_reviewed_source_on_acceptance(self):
        recognize(self.page, self.source, self.engine, 'fixture')
        original = self.page['dialogues'][0]
        apply_edit(self.page, dict(op='edit', id=original['id'], text='山の'))
        initial_id, initial_area = original['id'], original['area']
        failed = recognize_candidate(self.page, self.source, mock.Mock(side_effect=RuntimeError('model')), 'v2')
        self.assertEqual((failed['status'], self.page['status'], original['text']), ('failed', 'edited', '山の'))
        proposed = recognize_candidate(self.page, self.source, self.engine, 'v2')
        suggestion = proposed['dialogues'][0]
        self.assertEqual((original['text'], original['revision'], len(self.page['observations'])), ('山の', 2, 2))
        apply_edit(self.page, dict(op='accept-ocr', candidate=suggestion['id'], id=initial_id))
        self.assertEqual((original['text'], original['id'], original['area']), ('山', initial_id, initial_area))
        self.assertEqual(original['sourceHistory'][-1]['text'], '山の')
        self.assertEqual(len(self.page['observations']), 3)
        with self.assertRaises(ValueError):
            apply_edit(self.page, dict(op='accept-ocr', candidate=suggestion['id'], id=initial_id))

    def test_detached_publication(self):
        dest = self.root / 'r1'
        with self.assertRaises(ValueError):
            publish(self.project, dest)
        for page in self.project['pages']:
            recognize(page, self.source, self.engine, 'fixture')
        publish(self.project, dest)
        acbf = (dest / 'book.acbf').read_bytes()
        manifest = json.loads((dest / 'book.pages.json').read_bytes())
        self.assertEqual(manifest['acbfSha256'], digest(acbf))
        self.assertEqual(manifest['pages'][0]['layers']['ja'], [item['id'] for item in self.page['dialogues']])
        self.assertEqual([node.text for node in xml.fromstring(acbf).iter(TAG + 'p')], ['山', '下'] * 2)
        with self.assertRaises(ValueError):
            publish(self.project, dest)

    def test_unsafe_archive_page(self):
        cbz = self.root / 'bad.cbz'
        with zipfile.ZipFile(cbz, 'w') as archive:
            archive.writestr('../page.png', b'image')
        with self.assertRaises(ValueError), ChapterSource(cbz):
            self.fail('unsafe page accepted')
