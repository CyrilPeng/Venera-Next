import http.server
import json
import threading
import unittest
from unittest import mock

from exchange import encode
from project import apply_edit, new_dialogue
from translation import approve, current_translation, prepare, receive, send


class TranslationTest(unittest.TestCase):
    def setUp(self):
        self.items = [new_dialogue(content, [1, 2, 10, 20], []) for content in ['入口', '山の下', '空', '鳥']]
        self.page = dict(id='p1', sourceLanguage='ja', image='001.png', sha256='a' * 64, size=[200, 300],
                         status='edited', dialogues=self.items, observations=[], lineage=[])
        self.project = dict(title='山路', pages=[self.page], source='/private/path', id='work')
        self.batch, = prepare(self.project, 'en', glossary={'山': 'mountain'})

    def reply(self, batch):
        return dict(batch=batch['batch'], target=batch['target'], items=[{**row, 'text': 'Translation ' + row['text']}
                    for row in reversed(batch['items'])])

    def test_reorder_missing_duplicate_unknown_and_changed_source(self):
        reply = self.reply(self.batch)
        first, second, third, fourth = [item['id'] for item in self.items]
        reply['items'].pop(2)
        reply['items'].extend([{**reply['items'][1]}, dict(id='unknown', revision=1, text='?')])
        apply_edit(self.page, dict(op='edit', id=fourth, text='小鳥'))
        result = receive(self.project, reply)
        self.assertEqual(result, dict(accepted=1, issues={second: 'missing', third: 'duplicate', fourth: 'stale', 'unknown': 'unknown'}))
        retry, = prepare(self.project, 'en')
        self.assertEqual([row['id'] for row in retry['items']], [second, third, fourth])
        self.assertEqual(receive(self.project, self.reply(retry)), dict(accepted=3, issues={}))
        approve(self.project, 1, first, self.batch['batch'], 'Entrance')
        self.assertEqual(current_translation(self.items[0], 'en')['text'], 'Entrance')
        apply_edit(self.page, dict(op='edit', id=first, text='入り口'))
        self.assertIsNone(current_translation(self.items[0], 'en'))
        with self.assertRaises(ValueError):
            approve(self.project, 1, first, self.batch['batch'])
        self.assertEqual(self.items[0]['translations']['en'][0]['text'], 'Entrance')

    def test_review_history_and_two_languages(self):
        item = self.items[0]
        for lang in ('en', 'zh'):
            batch, = prepare(self.project, lang)
            reply = self.reply(batch)
            receive(self.project, reply)
            receive(self.project, reply)
            self.assertIsNone(current_translation(item, lang))
            approve(self.project, 1, item['id'], batch['batch'], lang + ' one')
            retry, = prepare(self.project, lang, redo=True)
            receive(self.project, self.reply(retry))
            self.assertEqual(current_translation(item, lang)['text'], lang + ' one')
            approve(self.project, 1, item['id'], retry['batch'], lang + ' two')
            self.assertEqual([rec['text'] for rec in item['translations'][lang]], [lang + ' one', lang + ' two'])
        files = encode(self.project)
        layers = json.loads(files['book.pages.json'])['pages'][0]['layers']
        self.assertEqual(layers['en'], layers['zh'])
        self.assertEqual(layers['zh'], [item['id']])
        self.assertIn(b'zh two', files['book.acbf'])

    def test_network_preview_authorization_and_text_only_exchange(self):
        captured = []
        expected = self.reply(self.batch)

        class Provider(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                captured.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(json.dumps(dict(choices=[dict(message=dict(content=json.dumps(expected)))])).encode())

            def log_message(self, *args):
                pass

        with http.server.HTTPServer(('127.0.0.1', 0), Provider) as server:
            endpoint = f'http://127.0.0.1:{server.server_port}/v1/chat/completions'
            with self.assertRaises(ValueError):
                send(self.batch, endpoint, 'fixture', None)
            self.assertEqual(captured, [])
            worker = threading.Thread(target=server.handle_request, daemon=True)
            worker.start()
            with mock.patch.dict('os.environ', {'SUBTITLE_TRANSLATION_KEY': '', 'no_proxy': '127.0.0.1'}):
                reply, elapsed = send(self.batch, endpoint, 'fixture', endpoint)
            worker.join(2)
            self.assertGreaterEqual(elapsed, 0)
            self.assertEqual(reply, expected)
        payload = json.loads(captured[0]['messages'][1]['content'])
        self.assertEqual(set(payload), {'batch', 'source', 'target', 'glossary', 'items'})
        self.assertEqual(set(payload['items'][0]), {'id', 'revision', 'text'})
