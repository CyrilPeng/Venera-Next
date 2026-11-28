"""Publish with Python, rewrite with the Dart reader, reopen and verify with Python."""

import base64
import json
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as xml
import zipfile
from pathlib import Path

from exchange import TAG, decode, encode, import_revision, pack, publish
from project import ChapterSource, digest, require


def main():
    repo = Path(__file__).resolve().parents[2]
    fixtures = repo / 'spec/comic-subtitles/fixtures'
    original = (fixtures / 'editorial.acbf').read_bytes()
    manifest = (fixtures / 'editorial.pages.json').read_bytes()
    dart = shutil.which('dart')
    require(dart is not None, 'Dart SDK required')
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        images = root / 'images'
        images.mkdir()
        data = base64.b64decode(xml.parse(fixtures / 'three-pages.acbf').find(f'.//{TAG}binary').text)
        (images / 'ridge.png').write_bytes(data)
        with ChapterSource(images) as source:
            project = decode(original, manifest, source)
        publish(project, root / 'python')
        report = subprocess.run([dart, str(repo / 'tool/comic_subtitles/inspect.dart'),
                                 str(root / 'python/book.acbf'), str(root / 'python/book.pages.json'),
                                 str(root / 'dart'), '0001.png'], cwd=repo, check=True, capture_output=True)
        read, = json.loads(report.stdout)
        require([area['text'] for area in read['dialogues']] == ['山の下', 'Mountain ', 'foot', 'Beneath the peak'],
                'Dart text differs')
        with ChapterSource(images) as source:
            imported = import_revision(source, root / 'dart')
        target = root / 'annotated.cbz'
        pack(imported, target)
        with ChapterSource(target) as source:
            restored = import_revision(source)
        final = encode(restored)
        expected = json.loads(manifest)
        result = json.loads(final['book.pages.json'])
        for key in ('workId', 'profile', 'requires', 'pages'):
            require(result[key] == expected[key], 'Round trip differs in ' + key)
        require(result['acbfSha256'] == digest(final['book.acbf']), 'Rewritten revision digest differs')
        require(xml.fromstring(final['book.acbf']).find(f'{TAG}body/{TAG}page/{TAG}image').get('href') == '0001.png',
                'Archive reference differs')
        pack(restored, root / 'plain.cbz', plain=True)
        for name in ('annotated.cbz', 'plain.cbz'):
            with zipfile.ZipFile(root / name) as archive:
                require(archive.read('0001.png') == data, 'Original image bytes differ')
    print('Python → Dart → Python: editorial fields, four regions, three editions and both CBZ forms passed.')


if __name__ == '__main__':
    main()
