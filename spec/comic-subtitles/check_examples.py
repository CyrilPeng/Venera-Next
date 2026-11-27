import argparse
import base64
import hashlib
import io
import json
import struct
import unittest
import xml.etree.ElementTree as xml
import zipfile
from copy import deepcopy
from pathlib import Path


FIXTURES = Path(__file__).resolve().parent / 'fixtures'
NAMESPACE = 'http://www.acbf.info/xml/acbf/1.1'
PREFIX = '{' + NAMESPACE + '}'
xml.register_namespace('', NAMESPACE)


def read_examples():
    cases = json.loads((FIXTURES / 'dialogues.json').read_text(encoding='utf-8'))
    original = xml.parse(FIXTURES / 'three-pages.acbf').getroot()
    images = {
        node.attrib['id']: base64.b64decode(node.text, validate=True)
        for node in original.findall(f'{PREFIX}data/{PREFIX}binary')
    }
    return cases, original, images


def public_body(pages):
    body = xml.Element(PREFIX + 'body')
    for page in pages:
        node = xml.SubElement(body, PREFIX + 'page')
        xml.SubElement(node, PREFIX + 'image', href='#' + page['image'])
        layers = {}
        for dialogue in page['dialogues']:
            left, top, right, bottom = dialogue['area']
            polygon = f'{left},{top} {right},{top} {right},{bottom} {left},{bottom}'
            for lang, text in dialogue['texts'].items():
                if lang not in layers:
                    layers[lang] = xml.SubElement(node, PREFIX + 'text-layer', lang=lang)
                area = xml.SubElement(layers[lang], PREFIX + 'text-area', points=polygon)
                xml.SubElement(area, PREFIX + 'p').text = text
    return body


def portable_files(cases, original, images):
    root = xml.Element(PREFIX + 'ACBF')
    root.append(deepcopy(original.find(PREFIX + 'meta-data')))
    root.append(public_body(cases['pages']))
    names = {page['image']: f'{index:03}.png' for index, page in enumerate(cases['pages'], 1)}
    for ref in root.iter(PREFIX + 'image'):
        ref.set('href', names[ref.attrib['href'].removeprefix('#')])
    files = {name: images[key] for key, name in names.items()}
    files['book.acbf'] = xml.tostring(root, encoding='utf-8', xml_declaration=True)
    bindings = []
    for page in cases['pages']:
        layers = {}
        for dialogue in page['dialogues']:
            for language in dialogue['texts']:
                layers.setdefault(language, []).append(dialogue['id'])
        bindings.append({**{key: page[key] for key in ('id', 'size', 'sha256', 'sourceLanguage')}, 'layers': layers})
    manifest = {'profile': 'venera-subtitles-experiment-1',
                'acbfSha256': hashlib.sha256(files['book.acbf']).hexdigest(), 'pages': bindings}
    files['book.pages.json'] = json.dumps(manifest, ensure_ascii=False, indent=2).encode('utf-8')
    return files


def make_cbz(files):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, content in files.items():
            archive.writestr(name, content)
    return buffer.getvalue()


def match_pages(files, digest):
    return [name for name, data in files.items() if hashlib.sha256(data).hexdigest() == digest]


def split_highlights(area, size, *, right_first):
    left, top, right, bottom = area
    width, height = size
    middle = width // 2
    offsets = (middle, 0) if right_first else (0, middle)
    rectangles = []
    for row, start in enumerate(offsets):
        clipped_left, clipped_right = max(start, left), min(start + middle, right)
        if clipped_left < clipped_right:
            rectangles.append((clipped_left - start, row * height + top,
                               clipped_right - start, row * height + bottom))
    return rectangles


class SubtitleExamples(unittest.TestCase):
    def setUp(self):
        self.cases, self.original, self.images = read_examples()
        self.pages = self.cases['pages']

    def test_page_identity(self):
        for page in self.pages:
            data = self.images[page['image']]
            self.assertEqual(data[:8], b'\x89PNG\r\n\x1a\n')
            self.assertEqual(list(struct.unpack('>II', data[16:24])), page['size'])
            self.assertEqual(hashlib.sha256(data).hexdigest(), page['sha256'])

    def test_acbf_round_trip(self):
        expected = self.original.find(PREFIX + 'body')
        actual = xml.fromstring(xml.tostring(public_body(self.pages)))
        self.assertEqual(
            xml.canonicalize(xml.tostring(actual), strip_text=True),
            xml.canonicalize(xml.tostring(expected), strip_text=True),
        )

    def test_authoring_data_loss(self):
        before = xml.tostring(public_body(self.pages))
        for field, value in dict(id='reassigned', observations=[], reviewed=[], direction='horizontal-tb').items():
            with self.subTest(field=field):
                edited = deepcopy(self.pages)
                edited[0]['dialogues'][0][field] = value
                self.assertEqual(before, xml.tostring(public_body(edited)))

    def test_offline_search_targets(self):
        detached = xml.fromstring(portable_files(self.cases, self.original, self.images)['book.acbf'])
        image_pages = detached.findall(f'{PREFIX}body/{PREFIX}page')
        for case in self.cases['searchCases']:
            hits = set()
            for number, page in enumerate(image_pages, 1):
                for text_area in page.iter(PREFIX + 'text-area'):
                    if case['query'] in ''.join(text_area.itertext()):
                        hits.add((number, text_area.attrib['points']))
            left, top, right, bottom = case['area']
            self.assertEqual(hits, {(case['page'], f'{left},{top} {right},{top} {right},{bottom} {left},{bottom}')})
            identities = [(number, item['id']) for number, page in enumerate(self.pages, 1)
                          for item in page['dialogues'] if any(case['query'] in text for text in item['texts'].values())]
            self.assertEqual(identities, [(case['page'], case['id'])])

    def test_repack_and_edition_conflicts(self):
        files = portable_files(self.cases, self.original, self.images)
        with zipfile.ZipFile(io.BytesIO(make_cbz(files))) as archive:
            self.assertEqual(archive.read('book.acbf'), files['book.acbf'])
            packed = {name: archive.read(name) for name in archive.namelist() if name.endswith('.png')}
        ref = xml.fromstring(files['book.acbf'])
        page_images = [node.attrib['href'] for node in ref.findall(f'{PREFIX}body/{PREFIX}page/{PREFIX}image')]
        self.assertEqual(page_images, ['001.png', '002.png', '003.png'])
        for page, new_name in zip(self.pages, page_images):
            self.assertEqual(match_pages(packed, page['sha256']), [new_name])
        gate_digest = self.pages[1]['sha256']
        packed['insert.png'] = packed['002.png']
        self.assertEqual(match_pages(packed, gate_digest), ['002.png', 'insert.png'])
        del packed['insert.png']
        replacement = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAYAAAADAAQAAAAAlk4nKAAAAIElEQVR4nO3BMQEAAADCoPVPbQwfoAAAAAAAAAAAAD4GJMAAAWNnguIAAAAASUVORK5CYII=')
        self.assertEqual(replacement[16:24], packed['002.png'][16:24])
        packed['002.png'] = replacement
        self.assertEqual(match_pages(packed, gate_digest), [])

    def test_split_page_projection(self):
        gate = self.pages[1]
        area = gate['dialogues'][0]['area']
        self.assertEqual(split_highlights(area, gate['size'], right_first=True),
                         [(0, 46, 56, 108), (136, 238, 192, 300)])
        self.assertEqual(split_highlights(area, gate['size'], right_first=False),
                         [(136, 46, 192, 108), (0, 238, 56, 300)])

    def test_experimental_page_manifest(self):
        files = portable_files(self.cases, self.original, self.images)
        manifest = json.loads(files['book.pages.json'])
        self.assertEqual(manifest['acbfSha256'], hashlib.sha256(files['book.acbf']).hexdigest())
        self.assertEqual(manifest['pages'][1]['layers'], {'ja': ['gate-entry'], 'zh': ['gate-entry']})
        self.assertEqual(manifest['pages'][2]['sha256'], hashlib.sha256(files['003.png']).hexdigest())


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Verify the three-page comic subtitle examples offline.')
    parser.add_argument('--export-dir', type=Path, help='Create a new directory with PNGs, book.acbf and a CBZ.')
    options = parser.parse_args()
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(SubtitleExamples)
    if not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful():
        raise SystemExit(1)
    if options.export_dir:
        files = portable_files(*read_examples())
        options.export_dir.mkdir(exist_ok=False)
        for name, content in files.items():
            (options.export_dir / name).write_bytes(content)
        (options.export_dir / 'three-pages.cbz').write_bytes(make_cbz(files))
