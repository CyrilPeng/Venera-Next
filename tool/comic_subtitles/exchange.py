"""Write one immutable, detached subtitle revision."""

import os
import json
import re
import tempfile
import xml.etree.ElementTree as xml
import zipfile
from pathlib import Path
from collections import defaultdict, deque

from project import ChapterSource, digest, json_bytes, language, region, relative_name, require, text, upright
from translation import current_translation


NS = 'http://www.acbf.info/xml/acbf/1.1'
TAG = '{' + NS + '}'
PROFILE = 'comic-subtitles/0.1'
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


def public_dialogue(item):
    result = {key: item[key] for key in ('id', 'area', 'text', 'revision', 'reviewed', 'direction', 'observations')}
    if item.get('sourceHistory'):
        result['sourceHistory'] = item['sourceHistory']
    approved = {lang: [{key: record[key] for key in ('batch', 'sourceRevision', 'approved', 'text')}
                       for record in history if record['approved']] for lang, history in item.get('translations', {}).items()}
    if any(approved.values()):
        result['translations'] = {lang: history for lang, history in approved.items() if history}
    return result


def preserve_layer_order(layer, keys, previous):
    pending = defaultdict(deque)
    for key, area in zip(keys, layer):
        pending[key].append(area)
    ordered = []
    for key in [*previous, *keys]:
        if pending[key]:
            ordered.append((key, pending[key].popleft()))
    layer[:] = [area for key, area in ordered]
    keys[:] = [key for key, area in ordered]


def encode(project):
    root = xml.Element(TAG + 'ACBF')
    if project.get('bookMetadata'):
        metadata = xml.fromstring(project['bookMetadata'])
        root.append(metadata)
        cover_page = next(page for page in project['pages'] if page['id'] == project['coverPageId'])
        metadata.find(f'{TAG}book-info/{TAG}coverpage/{TAG}image').set('href', cover_page['image'])
    else:
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
                    parts = item.get('layouts', {}).get(target, [])
                    if not parts or ''.join(part['text'] for part in parts) != record['text']:
                        parts = [dict(area=item['area'], text=record['text'])]
                    for part in parts:
                        add_area(translations[target], region(part['area'], page['size']), part['text'])
                        layers[target].append(item['id'])
                        total += 1
            for target, previous in page.get('layoutOrder', {}).items():
                if target in translations:
                    preserve_layer_order(translations[target], layers[target], previous)
        editorial = dict(observations=page['observations'], dialogues=[public_dialogue(item) for item in page['dialogues']],
                         lineage=[dict(operation=event['operation'], new=event['new'], old=[public_dialogue(item) for item in event['old']])
                                  for event in page['lineage']])
        bindings.append({**{key: page[key] for key in ('id', 'size', 'sha256', 'sourceLanguage')}, 'layers': layers, 'editorial': editorial})
    acbf = xml.tostring(root, encoding='utf-8', xml_declaration=True)
    manifest = json_bytes(dict(profile=PROFILE, requires=['editorial-1'], workId=project['id'], acbfSha256=digest(acbf), pages=bindings))
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


def parse_layer(layer, keys, size):
    areas = layer.findall(TAG + 'text-area')
    require(len(areas) == len(keys), 'Layer count differs')
    entries = []
    for area, key in zip(areas, keys):
        require(set(area.attrib) == {'points'} and all(para.tag == TAG + 'p' and not para.attrib for para in area),
                'Unsupported text styling requires a preserving editor')
        points = [tuple(map(int, pair.split(','))) for pair in area.attrib['points'].split()]
        xs, ys = zip(*points)
        box = region([min(xs), min(ys), max(xs), max(ys)], size)
        require(len(points) == 4 and set(points) == {(xx, yy) for xx in (box[0], box[2]) for yy in (box[1], box[3])},
                'Author import supports rectangular regions')
        paragraphs = area.findall(TAG + 'p')
        require(all(not len(para) for para in paragraphs), 'Styled paragraphs require a preserving editor')
        entries.append((key, dict(area=box, text=text('\n'.join(para.text or '' for para in paragraphs)))))
    return entries


def bounded_file(path):
    with path.open('rb') as handle:
        data = handle.read((16 << 20) + 1)
    require(len(data) <= 16 << 20, 'Subtitle exceeds size limit')
    return data


def known_fields(value, names):
    require(isinstance(value, dict) and not value.keys() - set(names.split()), 'An extension requires a preserving editor')


def check_editorial(editorial, size):
    known_fields(editorial, 'dialogues observations lineage')
    observations = set()
    directions = {'horizontal-tb', 'vertical-rl', 'vertical-lr'}
    for raw in editorial['observations']:
        known_fields(raw, 'id text quad confidence direction')
        text(raw['text'])
        require(isinstance(raw['id'], str) and raw['id'] not in observations and raw['direction'] in directions and
                type(raw['confidence']) in (int, float) and 0 <= raw['confidence'] <= 1 and len(raw['quad']) == 4 and
                all(len(point) == 2 and all(type(value) is int and 0 <= value <= maximum
                                           for value, maximum in zip(point, size)) for point in raw['quad']), 'Invalid observation')
        observations.add(raw['id'])
    records = list(editorial['dialogues'])
    for event in editorial['lineage']:
        known_fields(event, 'operation old new')
        require(event['operation'] in ('split', 'merge') and event['new'] and event['old'], 'Invalid lineage')
        records.extend(event['old'])
    for item in records:
        known_fields(item, 'id area text revision reviewed direction observations sourceHistory translations')
        text(item['text'])
        region(item['area'], size)
        require(type(item['revision']) is int and item['revision'] >= 1 and type(item['reviewed']) is bool and
                item['direction'] in directions and set(item['observations']) <= observations, 'Invalid editorial dialogue')
        for lang, history in item.get('translations', {}).items():
            language(lang)
            for record in history:
                known_fields(record, 'batch text approved sourceRevision')
                require(record['approved'] is True and type(record['sourceRevision']) is int and
                        1 <= record['sourceRevision'] <= item['revision'], 'Invalid approved translation')
                text(record['text'])


def decode(acbf, manifest, source):
    require(len(acbf) + len(manifest) <= 16 << 20, 'Subtitle exceeds size limit')
    content = acbf.decode('utf-8')
    body_text = re.sub(r'^\s*<\?xml\s+[^?]*\?>', '', content, count=1)
    require('<!' not in content and '<?' not in body_text, 'Unsupported XML declaration')
    root = xml.fromstring(content)
    meta = json.loads(manifest.decode('utf-8'))
    known_fields(meta, 'profile workId requires pages acbfSha256')
    require(root.tag == TAG + 'ACBF' and meta['acbfSha256'] == digest(acbf), 'Subtitle revision mismatch')
    require(meta.get('profile') == PROFILE and meta.get('requires') == ['editorial-1'], 'Unsupported editing profile or capability')
    metadata = root.find(TAG + 'meta-data')
    body = root.find(TAG + 'body')
    require(not root.attrib and len(root) == 2 and metadata is not None and body is not None and not body.attrib and
            all(node.tag == TAG + 'page' for node in body), 'Unsupported ACBF content requires a preserving editor')
    cover = metadata.find(f'{TAG}book-info/{TAG}coverpage/{TAG}image')
    require(cover is not None, 'Missing cover image')
    cover_id = None
    pages = list(body)
    require(0 < len(pages) == len(meta['pages']) <= 2048, 'Invalid page count')
    by_digest = {}
    for name in source.names:
        by_digest.setdefault(digest(source.read(name)), []).append(name)
    result = []
    ids, page_ids, used = set(), set(), set()
    area_count = 0
    for node, binding in zip(pages, meta['pages']):
        known_fields(binding, 'id size sha256 sourceLanguage layers editorial')
        require(not node.attrib and all(part.tag in (TAG + 'image', TAG + 'text-layer') for part in node) and
                len(node.findall(TAG + 'image')) == 1, 'Unsupported page content requires a preserving editor')
        name = node.find(TAG + 'image').attrib['href']
        require(relative_name(name), 'Unsafe relative image name')
        if cover.attrib.get('href') == name:
            cover_id = binding['id']
        candidates = by_digest.get(binding['sha256'], [])
        if name not in candidates:
            require(len(candidates) == 1, 'Original image missing or ambiguous')
            name = candidates[0]
        require(binding['id'] not in page_ids and name not in used, 'Duplicate page binding')
        used.add(name)
        page_ids.add(binding['id'])
        original = language(binding['sourceLanguage'])
        size = binding['size']
        require(len(size) == 2 and all(type(part) is int and part > 0 for part in size) and size[0] * size[1] <= 64_000_000,
                'Invalid page dimensions')
        with upright(source.read(name)) as image:
            require(list(image.size) == size, 'Original image dimensions differ')
        editorial = binding['editorial']
        check_editorial(editorial, size)
        dialogues = editorial['dialogues']
        originals = binding['layers'].get(original, [])
        require(originals == [item['id'] for item in dialogues] and len(set(originals)) == len(originals) and
                not ids.intersection(originals), 'Invalid dialogue identity or order')
        ids.update(originals)
        by_id = {item['id']: item for item in dialogues}
        layers = node.findall(TAG + 'text-layer')
        layer_names = [layer.attrib['lang'] for layer in layers]
        require(len(layer_names) == len(set(layer_names)) and set(layer_names) == set(binding['layers']), 'Layer language mismatch')
        for layer in layers:
            require(set(layer.attrib) == {'lang'} and all(area.tag == TAG + 'text-area' for area in layer),
                    'Unsupported layer content requires a preserving editor')
            lang = language(layer.attrib['lang'])
            parts = parse_layer(layer, binding['layers'][lang], size)
            area_count += len(parts)
            require(area_count <= 50000, 'Too many regions')
            for key, part in parts:
                require(key in by_id, 'Unknown dialogue ID')
                item = by_id[key]
                if lang == original:
                    require(part == dict(text=item['text'], area=item['area']), 'Source layer differs from editorial text or geometry')
                else:
                    item.setdefault('layouts', {}).setdefault(lang, []).append(part)
        for item in dialogues:
            targets = {lang for lang in item.get('translations', {}) if current_translation(item, lang)}
            require(targets == set(item.get('layouts', {})), 'Confirmed translation layer missing')
            for lang, parts in item.get('layouts', {}).items():
                require(current_translation(item, lang)['text'] == ''.join(part['text'] for part in parts), 'Translated text differs')
        result.append({**{key: binding[key] for key in ('id', 'size', 'sha256', 'sourceLanguage')}, **editorial,
                       'layoutOrder': {lang: keys for lang, keys in binding['layers'].items() if lang != original},
                       'image': name, 'status': 'edited' if dialogues else 'empty'})
    title = root.findtext(f'{TAG}meta-data/{TAG}book-info/{TAG}book-title') or 'Comic'
    require(cover_id is not None, 'A separate cover requires a preserving editor')
    return dict(version=1, id=meta['workId'], title=title, source=str(source.path), pages=result,
                bookMetadata=xml.tostring(metadata, encoding='unicode'), coverPageId=cover_id)


def import_revision(source, directory=None):
    if directory:
        return decode(bounded_file(directory / 'book.acbf'), bounded_file(directory / 'book.pages.json'), source)
    require(source.archive is not None, 'Select a subtitle directory or an annotated CBZ')
    payload = []
    for name in ('book.acbf', 'book.pages.json'):
        members = [info for info in source.archive.infolist() if info.filename == name]
        require(len(members) == 1 and members[0].file_size <= 16 << 20, 'Missing or oversized subtitle member')
        with source.archive.open(members[0]) as stream:
            payload.append(stream.read((16 << 20) + 1))
    return decode(*payload, source)


def pack(project, destination, plain=False):
    require(not destination.exists(), 'Choose a new CBZ filename')
    renamed = []
    with tempfile.TemporaryDirectory(dir=destination.parent) as tmp:
        output = Path(tmp) / 'book.cbz'
        with zipfile.ZipFile(output, 'w') as archive, ChapterSource(project['source']) as source:
            for number, page in enumerate(project['pages'], 1):
                data = source.read(page['image'])
                require(digest(data) == page['sha256'], 'Original page bytes changed')
                name = f'{number:04}{Path(page["image"]).suffix.lower()}'
                archive.writestr(name, data)
                renamed.append({**page, 'image': name})
            if not plain:
                for name, data in encode({**project, 'pages': renamed}).items():
                    archive.writestr(name, data, compress_type=zipfile.ZIP_DEFLATED)
        if os.name == 'nt':
            os.rename(output, destination)
        else:
            os.link(output, destination)
