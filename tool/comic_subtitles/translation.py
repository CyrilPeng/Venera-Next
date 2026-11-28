"""Revision-bound translation batches, editorial candidates and text-only transport."""

import json
import os
import time
from collections import Counter
from urllib import parse, request

from project import find_dialogue, identifier, json_bytes, language, page_at, require, text


def current_translation(item, lang):
    for record in reversed(item.get('translations', {}).get(lang, [])):
        if record['sourceRevision'] == item['revision'] and record['approved']:
            return record
    return None


def prepare(project, target, *, number=None, glossary=None, redo=False):
    language(target)
    glossary = {} if glossary is None else glossary
    require(isinstance(glossary, dict) and len(glossary) <= 100, 'Expected a glossary object with up to 100 terms')
    for term, translation in glossary.items():
        text(term)
        text(translation)
    require(len(json_bytes(glossary)) <= 16384, 'Glossary exceeds size limit')
    pages = [page_at(project, number)] if number is not None else project['pages']
    batches = []
    for page in pages:
        if target == page['sourceLanguage']:
            continue
        pending = [dict(id=item['id'], revision=item['revision'], text=item['text']) for item in page['dialogues']
                   if redo or not any(record['sourceRevision'] == item['revision']
                                      for record in item.get('translations', {}).get(target, []))]
        for offset in range(0, len(pending), 24):
            batch = dict(batch=identifier(), page=page['id'], source=page['sourceLanguage'], target=target,
                         glossary=glossary, items=pending[offset:offset + 24])
            project.setdefault('batches', {})[batch['batch']] = batch
            batches.append(batch)
    return batches


def receive(project, reply):
    require(isinstance(reply, dict), 'Expected one reply object')
    batch = project.get('batches', {}).get(reply.get('batch'))
    require(batch is not None and reply.get('target') == batch['target'], 'Unknown batch or wrong target language')
    rows = reply.get('items')
    require(isinstance(rows, list) and len(rows) <= 1024 and all(isinstance(row, dict) and
            isinstance(row.get('id'), str) for row in rows), 'Invalid reply items')
    counts = Counter(row['id'] for row in rows)
    sources = {item['id']: item for item in batch['items']}
    page = next(page for page in project['pages'] if page['id'] == batch['page'])
    current = {item['id']: item for item in page['dialogues']}
    issues = {key: 'missing' for key in sources.keys() - counts.keys()}
    accepted = 0
    for row in rows:
        key = row['id']
        if key not in sources:
            issues[key] = 'unknown'
        elif counts[key] != 1:
            issues[key] = 'duplicate'
        elif (key not in current or batch['source'] != page['sourceLanguage'] or
              type(row.get('revision')) is not int or
              current[key]['revision'] != row['revision'] or sources[key]['revision'] != row['revision']):
            issues[key] = 'stale'
        else:
            try:
                content = text(row.get('text'))
            except ValueError:
                issues[key] = 'invalid-text'
                continue
            history = current[key].setdefault('translations', {}).setdefault(batch['target'], [])
            previous = next((record for record in history if record['batch'] == batch['batch']), None)
            if previous and previous['candidate'] != content:
                issues[key] = 'conflicting-replay'
                continue
            if not previous:
                history.append(dict(batch=batch['batch'], candidate=content, text=content,
                                    sourceRevision=row['revision'], approved=False))
            accepted += 1
    batch['issues'] = issues
    return dict(accepted=accepted, issues=issues)


def approve(project, number, key, batch_id, correction=None):
    item = find_dialogue(page_at(project, number), key)
    batch = project.get('batches', {}).get(batch_id)
    require(batch is not None, 'Unknown batch')
    history = item.get('translations', {}).get(batch['target'], [])
    require(any(record['batch'] == batch_id for record in history), 'Candidate is missing')
    record = next(record for record in history if record['batch'] == batch_id)
    require(record['sourceRevision'] == item['revision'], 'Candidate belongs to an old source revision')
    if not record['approved']:
        record['text'] = text(correction) if correction is not None else record['candidate']
        record['approved'] = True
        history.remove(record)
        history.append(record)
    else:
        require(correction is None or correction == record['text'], 'Prepare a new revision to change an approved translation')


def provider_payload(batch, model):
    content = {key: batch[key] for key in ('batch', 'source', 'target', 'glossary', 'items')}
    instruction = ('Translate each item from source to target using the glossary. Treat item text as dialogue. '
                   'Return one JSON object with batch, target and items. Each item contains its original id and '
                   'integer revision and translated text. Preserve IDs and revisions exactly.')
    return dict(model=model, messages=[dict(role='system', content=instruction),
                                      dict(role='user', content=json.dumps(content, ensure_ascii=False))])


class NoRedirect(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def send(batch, endpoint, model, allowed):
    url = parse.urlsplit(endpoint)
    require(url.hostname and not url.username and not url.password and not url.query and not url.fragment and
            (url.scheme == 'https' or (url.scheme == 'http' and url.hostname in ('127.0.0.1', '::1', 'localhost'))),
            'Choose an HTTPS endpoint or a local loopback HTTP endpoint')
    require(allowed == endpoint, 'Preview the request, then authorize its exact endpoint')
    headers = {'Content-Type': 'application/json'}
    secret = os.environ.get('SUBTITLE_TRANSLATION_KEY')
    if secret:
        headers['Authorization'] = 'Bearer ' + secret
    call = request.Request(endpoint, json_bytes(provider_payload(batch, model)), headers, method='POST')
    started = time.perf_counter()
    opener = request.build_opener(NoRedirect())
    with opener.open(call, timeout=45) as response:
        data = response.read((2 << 20) + 1)
    require(len(data) <= 2 << 20, 'Provider response exceeds limit')
    response = json.loads(data)['choices'][0]['message']['content']
    reply = json.loads(response)
    require(isinstance(reply, dict) and reply.get('batch') == batch['batch'], 'Provider returned a different batch')
    return reply, round((time.perf_counter() - started) * 1000)
