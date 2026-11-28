"""Write one immutable, detached subtitle revision."""

import os
import tempfile
import xml.etree.ElementTree as xml
from pathlib import Path

from project import digest, json_bytes, require
from translation import current_translation


NS = 'http://www.acbf.info/xml/acbf/1.1'
TAG = '{' + NS + '}'
PROFILE = 'venera-subtitles-experiment-1'
xml.register_namespace('', NS)


def child(parent, tag, content=None, **attrs):
    node = xml.SubElement(parent, TAG + tag, attrs)
    node.text = content
    return node


def add_area(layer, box, content):
    left, top, right, bottom = box
    area = child(layer, 'text-area', points=f'{left},{top} {right},{top} {right},{bottom} {left},{bottom}')
    for paragraph in content.split('\n'):
        child(area, 'p', paragraph)


def encode(project):
    root = xml.Element(TAG + 'ACBF')
    info = child(child(root, 'meta-data'), 'book-info')
    child(child(info, 'author'), 'nickname', 'Comic subtitle editor')
    child(info, 'book-title', project['title'])
    child(info, 'genre', 'other')
    child(child(info, 'coverpage'), 'image', href=project['pages'][0]['image'])
    body = child(root, 'body')
    bindings = []
    total = 0
    for page in project['pages']:
        require(page['status'] in ('recognized', 'edited', 'empty'), 'Unfinished OCR page')
        node = child(body, 'page')
        child(node, 'image', href=page['image'])
        lang = page['sourceLanguage']
        layers = {}
        if page['dialogues']:
            layer = child(node, 'text-layer', lang=lang)
            keys = layers[lang] = []
            for item in page['dialogues']:
                add_area(layer, item['area'], item['text'])
                keys.append(item['id'])
            total += len(keys)
            translations = {}
            for item in page['dialogues']:
                for target in item.get('translations', {}):
                    record = current_translation(item, target)
                    if record is None:
                        continue
                    if target not in translations:
                        translations[target] = child(node, 'text-layer', lang=target)
                        layers[target] = []
                    add_area(translations[target], item['area'], record['text'])
                    layers[target].append(item['id'])
                    total += 1
        bindings.append({**{key: page[key] for key in ('id', 'size', 'sha256', 'sourceLanguage')}, 'layers': layers})
    acbf = xml.tostring(root, encoding='utf-8', xml_declaration=True)
    manifest = json_bytes(dict(profile=PROFILE, acbfSha256=digest(acbf), pages=bindings))
    require(total <= 50000 and len(acbf) + len(manifest) <= 16 << 20, 'Published subtitles exceed reader limits')
    return {'book.acbf': acbf, 'book.pages.json': manifest}


def publish(project, destination):
    files = encode(project)
    destination = Path(destination)
    require(not destination.exists(), 'Choose a new revision directory')
    with tempfile.TemporaryDirectory(dir=destination.parent) as temporary:
        revision = Path(temporary) / 'revision'
        revision.mkdir()
        for name, content in files.items():
            (revision / name).write_bytes(content)
        os.rename(revision, destination)
