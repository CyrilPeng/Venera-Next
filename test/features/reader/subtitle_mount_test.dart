import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/reader/subtitles/binding.dart';
import 'package:venera_next/features/reader/subtitles/document.dart';
import 'package:venera_next/features/reader/subtitles/store.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));
final _acbf = File(
  'spec/comic-subtitles/fixtures/three-pages.acbf',
).readAsBytesSync();
final _pages =
    jsonDecode(
          File(
            'spec/comic-subtitles/fixtures/dialogues.json',
          ).readAsStringSync(),
        )['pages']
        as List;

Uint8List _manifest() => _bytes(
  jsonEncode({
    'profile': 'venera-subtitles-experiment-1',
    'acbfSha256': sha256.convert(_acbf).toString(),
    'pages': [
      for (final page in _pages)
        {
          for (final key in ['id', 'size', 'sha256', 'sourceLanguage'])
            key: page[key],
          'layers': {
            for (final language
                in (page['dialogues'] as List)
                    .expand((item) => (item['texts'] as Map).keys)
                    .toSet())
              language: [
                for (final item in page['dialogues'])
                  if ((item['texts'] as Map).containsKey(language)) item['id'],
              ],
          },
        },
    ],
  }),
);

void main() {
  test(
    'ACBF regions retain order and page manifest restores bilingual identity',
    () {
      final document = SubtitleDocument.parse(_acbf, manifest: _manifest());
      expect(document.pages.map((page) => page.id), ['ridge', 'gate', 'dawn']);
      final first = document.pages.first;
      expect(first.areas.map((area) => area.text), ['山の下', '山脚下']);
      expect(first.areas.map((area) => area.dialogue).toSet(), {'ridge-foot'});
      expect(first.areas.first.bounds, (
        left: 52,
        top: 32,
        right: 139,
        bottom: 119,
      ));
      expect(document.pages.last.areas.last.dialogue, 'dawn-sunrise');
      expect(
        SubtitleDocument.parse(_acbf).pages[1].digest,
        _pages[1]['sha256'],
      );
      expect(
        () => SubtitleDocument.parse(
          _bytes('${utf8.decode(_acbf)}\n'),
          manifest: _manifest(),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'byte, page, region, text and pixel limits include their boundaries',
    () {
      expect(
        SubtitleDocument.parse(
          _acbf,
          limits: SubtitleLimits(
            bytes: _acbf.length,
            pages: 3,
            areas: 6,
            pixels: 192 * 768,
            textLength: 3,
          ),
        ).pages,
        hasLength(3),
      );
      for (final limit in [
        SubtitleLimits(bytes: _acbf.length - 1),
        const SubtitleLimits(pages: 2),
        const SubtitleLimits(areas: 5),
        const SubtitleLimits(pixels: 192 * 768 - 1),
        const SubtitleLimits(textLength: 2),
      ]) {
        expect(
          () => SubtitleDocument.parse(_acbf, limits: limit),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'relative image requires review and a confirmed digest survives rename',
    () async {
      final document = SubtitleDocument.parse(
        _bytes(
          '<ACBF xmlns="$subtitleNamespace"><body><page><image href="a.png"/></page></body></ACBF>',
        ),
      );
      final dir = await Directory.systemTemp.createTemp('subtitle-pages-');
      addTearDown(() => dir.delete(recursive: true));
      final original = await File(
        '${dir.path}/a.png',
      ).writeAsString('original');
      final files = await fingerprintSubtitleImages([
        'file://${original.path}',
      ]);
      final first = bindSubtitlePages(document, files, {}).single;
      expect(first.selected, isNull);
      final saved = {
        first.page.id: (path: original.path, digest: files.single.digest),
      };
      final renamed = await original.rename('${dir.path}/b.png');
      final duplicate = await renamed.copy(original.path);
      final repeated = await fingerprintSubtitleImages([
        'file://${renamed.path}',
        'file://${duplicate.path}',
      ]);
      expect(
        bindSubtitlePages(document, repeated, saved).single.selected?.number,
        2,
      );
      await duplicate.delete();
      final reordered = await fingerprintSubtitleImages([
        'file://${renamed.path}',
      ]);
      expect(
        bindSubtitlePages(document, reordered, saved).single.selected?.path,
        renamed.path,
      );
      await renamed.writeAsString('replaced');
      expect(
        bindSubtitlePages(
          document,
          await fingerprintSubtitleImages(['file://${renamed.path}']),
          saved,
        ).single.candidates,
        isEmpty,
      );
    },
  );

  test(
    'identical files and overlapping source pages never silently bind twice',
    () {
      final page = SubtitleDocument.parse(_acbf).pages[1];
      final files = [
        (path: 'one', digest: page.digest!, number: 3),
        (path: 'two', digest: page.digest!, number: 1),
      ];
      final ambiguous = bindSubtitlePages(
        SubtitleDocument([page]),
        files,
        {},
      ).single;
      expect(ambiguous.selected, isNull);
      expect(ambiguous.candidates, hasLength(2));
      expect(
        bindSubtitlePages(SubtitleDocument([page, page]), [
          files.first,
        ], {}).every((item) => item.selected == null),
        isTrue,
      );
    },
  );

  test(
    'interrupted replacement, stale writer, restart and chapter detach',
    () async {
      final dir = await Directory.systemTemp.createTemp('subtitle-store-');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/state.db', store = SubtitleStore(path);
      final revision = SubtitleRevision(_acbf, _manifest(), {}, null);
      store.replace('comic', 'one', null, revision);
      store.replace('comic', 'two', null, revision);
      final old = store.read('comic', 'one')!;
      final db = sqlite3.open(path);
      db.execute(
        "CREATE TRIGGER interrupt BEFORE INSERT ON subtitle_chapters BEGIN SELECT RAISE(ABORT, 'interrupted'); END",
      );
      db.dispose();
      expect(
        () => store.replace('comic', 'one', old.token, revision),
        throwsA(isA<SqliteException>()),
      );
      expect(
        SubtitleStore(path).read('comic', 'one')!.parse().pages.first.id,
        'ridge',
      );
      expect(() => store.replace('comic', 'one', null, null), throwsStateError);
      store.replace('comic', 'one', old.token, null);
      expect(store.chapters('comic'), ['two']);
      expect(store.read('comic', 'one'), isNull);
    },
  );
}
