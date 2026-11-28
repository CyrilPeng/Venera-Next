"""Offline conformance checker for the detached Comic Subtitles 0.1 profile."""

import argparse
import hashlib
import json
import re
import xml.etree.ElementTree as xml
from collections import defaultdict
from pathlib import Path


TAG = '{http://www.acbf.info/xml/acbf/1.1}'
LIMIT = 16 << 20
DIRECTIONS = {'horizontal-tb', 'vertical-lr', 'vertical-rl'}


def check(valid, reason):
    if not valid:
        raise ValueError(reason)


def key(value):
    check(isinstance(value, str) and value.strip() and len(value) <= 512, 'invalid identifier')
    return value


def bounds(area, size):
    check(len(area) == 4 and all(type(part) is int for part in area) and
          0 <= area[0] < area[2] <= size[0] and 0 <= area[1] < area[3] <= size[1], 'invalid rectangle')
    return list(area)


def dialogues(page, source):
    editorial = page['editorial']
    original = page['sourceLanguage']
    items = editorial['dialogues']
    check([item['id'] for item in items] == page['layers'].get(original, []), 'source order differs')
    observations = set()
    for raw in editorial['observations']:
        identity = key(raw['id'])
        check(identity not in observations and isinstance(raw['text'], str) and raw['direction'] in DIRECTIONS and
              type(raw['confidence']) in (float, int) and 0 <= raw['confidence'] <= 1 and len(raw['quad']) == 4 and
              all(len(point) == 2 and all(type(value) is int and 0 <= value <= maximum
                                         for value, maximum in zip(point, page['size'])) for point in raw['quad']),
              'invalid observation')
        observations.add(identity)
    identities = set()
    for item in items:
        identity = key(item['id'])
        check(identity not in identities, 'duplicate dialogue')
        identities.add(identity)
        check(type(item['revision']) is int and item['revision'] > 0 and type(item['reviewed']) is bool and
              item['direction'] in DIRECTIONS and set(item['observations']) <= observations, 'invalid editorial dialogue')
        check(source.pop((identity, original), []) == [(item['text'], bounds(item['area'], page['size']))],
              'source text or geometry differs')
        for lang, records in item.get('translations', {}).items():
            active = None
            for record in records:
                key(record['batch'])
                check(record['approved'] is True and type(record['sourceRevision']) is int and
                      1 <= record['sourceRevision'] <= item['revision'] and isinstance(record['text'], str),
                      'invalid confirmed revision')
                if record['sourceRevision'] == item['revision']:
                    active = record['text']
            if active is not None:
                parts = source.pop((identity, lang), [])
                check(parts and ''.join(content for content, box in parts) == active, 'translation differs')
    check(not source, 'layer references missing dialogue or edition')
    historic = set()
    for event in editorial['lineage']:
        old = [key(item['id']) for item in event['old']]
        new = [key(identity) for identity in event['new']]
        check(len(old) == len(set(old)) and len(new) == len(set(new)) and not set(old).intersection(new) and
              ((event['operation'] == 'split' and len(old) == 1 and len(new) >= 2) or
               (event['operation'] == 'merge' and len(old) >= 2 and len(new) == 1)), 'invalid lineage')
        historic.update(old)
    check(all(set(event['new']) <= historic | identities for event in editorial['lineage']), 'lineage references missing dialogue')
    return identities


def validate(acbf, manifest, images=None):
    check(len(acbf) + len(manifest) <= LIMIT, 'subtitle exceeds byte limit')
    metadata = json.loads(manifest.decode('utf-8'))
    check(metadata['profile'] == 'comic-subtitles/0.1', 'unknown profile')
    check(isinstance(metadata['requires'], list) and set(metadata['requires']) == {'editorial-1'}, 'unknown required capability')
    key(metadata['workId'])
    check(metadata['acbfSha256'] == hashlib.sha256(acbf).hexdigest(), 'ACBF revision differs')
    content = acbf.decode('utf-8')
    check('<!DOCTYPE' not in content and '<?' not in re.sub(r'^\s*<\?xml\s+[^?]*\?>', '', content, count=1),
          'unsupported XML declaration')
    root = xml.fromstring(content)
    nodes = root.findall(f'{TAG}body/{TAG}page')
    check(root.tag == TAG + 'ACBF' and len(root.findall(TAG + 'body')) == 1 and
          0 < len(nodes) == len(metadata['pages']) <= 2048, 'invalid ACBF pages')
    page_ids, dialogue_ids = set(), set()
    regions = 0
    for page, node in zip(metadata['pages'], nodes):
        identity = key(page['id'])
        check(identity not in page_ids, 'duplicate page')
        page_ids.add(identity)
        size = page['size']
        check(len(size) == 2 and all(type(part) is int and part > 0 for part in size) and size[0] * size[1] <= 64_000_000,
              'invalid dimensions')
        check(re.fullmatch(r'[a-f0-9]{64}', page['sha256']), 'invalid image digest')
        refs = node.findall(TAG + 'image')
        check(len(refs) == 1, 'expected one page image')
        href = key(refs[0].attrib['href'])
        check(not re.search(r'[:\\%?#\x00-\x1f]', href) and all(part not in ('', '.', '..') for part in href.split('/')),
              'unsafe image reference')
        if images is not None:
            image = (images / href).resolve(strict=True)
            check(image.is_relative_to(images.resolve()), 'image outside chapter')
            checksum = hashlib.sha256()
            with image.open('rb') as stream:
                for chunk in iter(lambda: stream.read(262144), b''):
                    checksum.update(chunk)
            check(checksum.hexdigest() == page['sha256'], 'original image differs')
        source = defaultdict(list)
        languages = set()
        for layer in node.findall(TAG + 'text-layer'):
            lang = key(layer.attrib['lang'])
            check(lang not in languages and lang in page['layers'], 'unexpected language')
            languages.add(lang)
            parts = layer.findall(TAG + 'text-area')
            keys = page['layers'][lang]
            regions += len(parts)
            check(len(parts) == len(keys) and regions <= 50000, 'region count differs')
            for area, dialogue in zip(parts, keys):
                vertices = area.attrib['points'].split()
                check(3 <= len(vertices) <= 256, 'invalid polygon')
                coords = [tuple(map(int, point.split(','))) for point in vertices]
                check(all(len(point) == 2 for point in coords), 'invalid point')
                xs, ys = zip(*coords)
                box = bounds([min(xs), min(ys), max(xs), max(ys)], size)
                content = '\n'.join(''.join(para.itertext()) for para in area.findall(TAG + 'p'))
                check(len(content.encode('utf-16-le')) <= 131072, 'text exceeds limit')
                source[(key(dialogue), lang)].append((content, box))
        check(languages == set(page['layers']), 'missing language')
        ids = dialogues(page, source)
        check(not ids.intersection(dialogue_ids), 'dialogue occurs on multiple pages')
        dialogue_ids.update(ids)
    return {'pages': len(page_ids), 'dialogues': len(dialogue_ids), 'regions': regions}


def limited(path):
    with path.open('rb') as stream:
        return stream.read(LIMIT + 1)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('acbf', type=Path)
    parser.add_argument('manifest', type=Path)
    parser.add_argument('--images', type=Path, help='also verify relative image files against their digests')
    args = parser.parse_args()
    try:
        print(json.dumps(validate(limited(args.acbf), limited(args.manifest), args.images)))
    except (ValueError, OSError, KeyError, IndexError, TypeError, AttributeError, xml.ParseError) as error:
        parser.exit(1, f'Invalid subtitles: {error}\n')
