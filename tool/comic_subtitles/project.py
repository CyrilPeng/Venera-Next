"""Local chapter sources, recoverable OCR and editorial operations."""

import hashlib
import io
import json
import os
import re
import tempfile
import time
import uuid
import zipfile
from contextlib import contextmanager
from pathlib import Path, PurePosixPath

from PIL import Image, ImageOps


MAX_BYTES = 64 << 20
MAX_PIXELS = 64_000_000
MAX_PAGES = 2048
IMAGE_SUFFIXES = {'.png', '.jpg', '.jpeg', '.webp', '.bmp', '.gif'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def identifier():
    return uuid.uuid4().hex


def digest(data):
    return hashlib.sha256(data).hexdigest()


def language(value):
    require(isinstance(value, str) and re.fullmatch(r'[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*', value),
            'Expected a language tag such as ja or zh-Hans')
    return value


def text(value):
    require(isinstance(value, str) and value.strip() and len(value) <= 32768 and
            all(char in '\t\n' or ' ' <= char <= '\ud7ff' or '\ue000' <= char <= '\ufffd' or
                '\U00010000' <= char <= '\U0010ffff' for char in value), 'Invalid dialogue text')
    return value


def json_bytes(value):
    return json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False).encode('utf-8')


def read_json(path):
    with Path(path).open('rb') as handle:
        data = handle.read(MAX_BYTES + 1)
    require(len(data) <= MAX_BYTES, 'JSON exceeds size limit')
    return json.loads(data.decode('utf-8'))


def atomic_json(path, value):
    data = json_bytes(value)
    require(len(data) <= MAX_BYTES, 'Project exceeds size limit')
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as handle:
        tmp = Path(handle.name)
    try:
        with tmp.open('wb') as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


@contextmanager
def project_lock(path):
    with path.with_name(path.name + '.lock').open('a+b') as handle:
        if os.name == 'nt':
            import msvcrt
            handle.seek(0)
            msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


def relative_name(name):
    return (0 < len(name) <= 512 and not re.search(r'[:\\%?#\x00-\x1f]', name) and
            all(part not in {'', '.', '..'} for part in name.split('/')))


def natural(name):
    return [int(part) if position % 2 else part.casefold()
            for position, part in enumerate(re.split(r'(\d+)', name))]


class ChapterSource:
    def __init__(self, path):
        self.path = Path(path).resolve(strict=True)
        self.archive = None

    def __enter__(self):
        if self.path.is_dir():
            members = ((entry.relative_to(self.path).as_posix(), entry.stat().st_size)
                       for entry in self.path.rglob('*') if entry.is_file() and
                       entry.resolve().is_relative_to(self.path))
        else:
            require(self.path.stat().st_size <= 2 << 30, 'Archive exceeds 2 GiB')
            self.archive = zipfile.ZipFile(self.path)
            members = ((info.filename, info.file_size) for info in self.archive.infolist() if not info.is_dir())
        try:
            self.names = []
            seen = set()
            total = 0
            for count, (name, size) in enumerate(members, 1):
                require(count <= 20000, 'Too many entries')
                if PurePosixPath(name).suffix.lower() not in IMAGE_SUFFIXES:
                    continue
                require(relative_name(name) and name.casefold() not in seen, 'Unsafe or duplicate page name')
                total += size
                require(0 < size <= MAX_BYTES and total <= 2 << 30 and len(seen) < MAX_PAGES, 'Chapter exceeds limit')
                seen.add(name.casefold())
                self.names.append(name)
            require(self.names, 'No supported images in chapter')
            self.names.sort(key=lambda name: (natural(name), name))
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def __exit__(self, *args):
        if self.archive:
            self.archive.close()

    def read(self, name):
        require(name in self.names, 'Original page is missing')
        if self.archive:
            stream = self.archive.open(name)
        else:
            target = (self.path / name).resolve(strict=True)
            require(target.is_relative_to(self.path), 'Page outside chapter')
            stream = target.open('rb')
        with stream:
            data = stream.read(MAX_BYTES + 1)
        require(0 < len(data) <= MAX_BYTES, 'Image exceeds size limit')
        return data


def upright(data):
    with Image.open(io.BytesIO(data)) as image:
        require(image.width * image.height <= MAX_PIXELS, 'Image exceeds pixel limit')
        return ImageOps.exif_transpose(image).convert('RGB')


def create_project(source, source_language):
    pages = []
    for name in source.names:
        data = source.read(name)
        with Image.open(io.BytesIO(data)) as image:
            require(image.width * image.height <= MAX_PIXELS, 'Image exceeds pixel limit')
            size = image.size[::-1] if image.getexif().get(274) in (5, 6, 7, 8) else image.size
        pages.append(dict(id=identifier(), image=name, size=list(size), sha256=digest(data),
                          sourceLanguage=language(source_language), status='pending', observations=[], dialogues=[], lineage=[]))
    return dict(version=1, id=identifier(), title=source.path.stem, source=str(source.path), pages=pages)


def page_at(project, number):
    require(type(number) is int and 1 <= number <= len(project['pages']), 'Page number outside chapter')
    return project['pages'][number - 1]


def verified_image(source, page):
    data = source.read(page['image'])
    require(digest(data) == page['sha256'], 'Original page bytes have changed')
    return upright(data)


def region(box, size):
    require(isinstance(box, list) and len(box) == 4 and all(type(part) is int for part in box) and
            0 <= box[0] < box[2] <= size[0] and 0 <= box[1] < box[3] <= size[1], 'Invalid upright rectangle')
    return box


def new_dialogue(content, box, observations, direction='horizontal-tb', reviewed=False):
    return dict(id=identifier(), text=text(content), area=box, observations=observations, direction=direction,
                reviewed=reviewed, revision=1)


def recognize(page, source, engine, engine_name):
    started = time.perf_counter()
    try:
        with verified_image(source, page) as image:
            image.thumbnail((2048, 2048))
            rows = engine(image)[0]
            width, height = page['size']
            observations, dialogues = [], []
            for quad, content, score in rows or []:
                require(len(quad) == 4 and len(observations) < 8192 and 0 <= float(score) <= 1, 'Invalid OCR output')
                points = [[max(0, min(width, round(horizontal * width / image.width))),
                           max(0, min(height, round(vertical * height / image.height)))] for horizontal, vertical in quad]
                xs, ys = zip(*points)
                box = region([min(xs), min(ys), max(xs), max(ys)], page['size'])
                direction = 'vertical-rl' if box[3] - box[1] > box[2] - box[0] else 'horizontal-tb'
                observation = dict(id=identifier(), text=text(content), quad=points, confidence=float(score), direction=direction)
                observations.append(observation)
                dialogues.append(new_dialogue(content, box, [observation['id']], direction))
            page.update(status='recognized' if dialogues else 'empty', observations=observations, dialogues=dialogues,
                        ocr=dict(engine=engine_name, inputSize=list(image.size), uprightSize=page['size']))
            page.pop('error', None)
    except Exception as error:
        page.update(status='failed', error=str(error)[:500])
    page['elapsedMs'] = round((time.perf_counter() - started) * 1000)


def find_dialogue(page, key):
    matches = [item for item in page['dialogues'] if item['id'] == key]
    require(len(matches) == 1, 'Dialogue ID is missing or ambiguous')
    return matches[0]


def recognize_candidate(page, source, engine, engine_name):
    require(page['status'] in ('empty', 'recognized', 'edited'), 'Run the initial OCR first')
    candidate = {field: page[field] for field in ('image', 'size', 'sha256')}
    recognize(candidate, source, engine, engine_name)
    page['ocrCandidate'] = candidate
    return candidate


def accept_candidate(page, op):
    result = page.get('ocrCandidate')
    require(result is not None and result['status'] == 'recognized', 'No recognized candidates on this page')
    suggested = find_dialogue(result, op['candidate'])
    content = text(op.get('text', suggested['text']))
    if op.get('id'):
        target = find_dialogue(page, op['id'])
        apply_edit(page, dict(op='edit', id=target['id'], text=content))
    else:
        target = new_dialogue(content, suggested['area'], [], suggested['direction'], True)
        page['dialogues'].append(target)
    selected = set(suggested['observations'])
    page['observations'].extend(raw for raw in result['observations'] if raw['id'] in selected)
    target['observations'].extend(suggested['observations'])
    result['dialogues'].remove(suggested)


def apply_edit(page, op):
    items, action = page['dialogues'], op['op']
    require(page['status'] in ('empty', 'recognized', 'edited'), 'Recognize this page before editing')
    if action == 'accept-ocr':
        accept_candidate(page, op)
    elif action == 'language':
        require(not any(item.get('translations') for item in items), 'Change the language before translation')
        page['sourceLanguage'] = language(op['language'])
    elif action == 'add':
        items.append(new_dialogue(op['text'], region(op['area'], page['size']), [], reviewed=True))
    elif action == 'order':
        keys = op['ids']
        require(len(keys) == len(items) and set(keys) == {item['id'] for item in items}, 'Order must cover the page once')
        items[:] = [find_dialogue(page, key) for key in keys]
    elif action == 'edit':
        item = find_dialogue(page, op['id'])
        content = text(op.get('text', item['text']))
        if content != item['text']:
            item.setdefault('sourceHistory', []).append(dict(revision=item['revision'], text=item['text'], reviewed=item['reviewed']))
            item['revision'] += 1
        direction = op.get('direction', item['direction'])
        require(direction in ('horizontal-tb', 'vertical-rl', 'vertical-lr'), 'Invalid writing direction')
        item.update(text=content, reviewed=True, direction=direction, area=region(op.get('area', item['area']), page['size']))
    elif action in ('split', 'merge'):
        keys = [op['id']] if action == 'split' else op['ids']
        require(isinstance(keys, list) and len(set(keys)) == len(keys) and
                (action == 'split' or len(keys) >= 2), 'Select distinct dialogues to merge')
        old = [find_dialogue(page, key) for key in keys]
        if action == 'split':
            parts = op['parts']
            require(len(parts) >= 2, 'Split needs at least two parts')
        else:
            left, top, right, bottom = zip(*(item['area'] for item in old))
            parts = [dict(text=op.get('text', ''.join(item['text'] for item in old)),
                          area=[min(left), min(top), max(right), max(bottom)])]
        refs = list(dict.fromkeys(ref for item in old for ref in item['observations']))
        new = [new_dialogue(part['text'], region(part['area'], page['size']), refs, old[0]['direction'], True) for part in parts]
        first = min(items.index(item) for item in old)
        items[:] = [item for item in items if item['id'] not in keys]
        items[first:first] = new
        page['lineage'].append(dict(operation=action, old=old, new=[item['id'] for item in new]))
    else:
        raise ValueError('Unknown edit operation')
    page['status'] = 'edited'
