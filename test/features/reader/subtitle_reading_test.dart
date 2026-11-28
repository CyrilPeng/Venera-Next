import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/subtitles/binding.dart';
import 'package:venera_next/features/reader/subtitles/document.dart';
import 'package:venera_next/features/reader/subtitles/overlay.dart';
import 'package:venera_next/features/reader/subtitles/reading.dart';

const _region = (left: 50, top: 642, right: 150, bottom: 706);
const _page = SubtitlePage(
  'dawn',
  'dawn.png',
  null,
  'ja',
  [
    SubtitleArea('sunrise', 'ja', '入口の日出', _region),
    SubtitleArea('sunrise', 'zh', '入口日出', _region),
    SubtitleArea('sunrise', 'en', 'Sunrise', _region),
  ],
  192,
  768,
);
const _file = (path: 'dawn.png', digest: 'sample', number: 3);
ChapterSubtitleIndex _index() => ChapterSubtitleIndex('one', [
  const SubtitleBinding(_page, [_file], _file),
]);

void main() {
  test(
    'canonically equivalent Japanese and Latin queries share lookup text',
    () {
      expect(subtitleSearchText('カ\u3099'), subtitleSearchText('ガ'));
      expect(subtitleSearchText('E\u0301'), subtitleSearchText('é'));
    },
  );
  test(
    'bilingual matches share identity and language selection restricts results',
    () {
      final index = _index();
      expect(index.search('入口', 'zh').single.file.number, 3);
      expect(index.search('の日', 'en').single.area.dialogue, 'sunrise');
      expect(index.search('ＳＵＮ', 'en').single.area.language, 'en');
      expect(index.search('sun', 'zh'), isEmpty);
      expect(index.search(' ', 'en'), isEmpty);
      expect(
        ChapterSubtitleIndex('one', [
          const SubtitleBinding(_page, [], null),
        ]).search('日', null),
        isEmpty,
      );
    },
  );

  test(
    'split, crop and downsample project from original pixels to the painted rectangle',
    () {
      List<Rect> halves(bool invert) => projectSubtitleArea(
        area: (left: 136, top: 46, right: 248, bottom: 108),
        original: const Size(384, 192),
        decoded: const Size(192, 96),
        crop: const Rect.fromLTWH(0, 0, 192, 96),
        destination: const Rect.fromLTWH(0, 0, 192, 384),
        split: true,
        invert: invert,
      );
      expect(halves(false), [
        const Rect.fromLTRB(0, 46, 56, 108),
        const Rect.fromLTRB(136, 238, 192, 300),
      ]);
      expect(halves(true), [
        const Rect.fromLTRB(136, 46, 192, 108),
        const Rect.fromLTRB(0, 238, 56, 300),
      ]);
      expect(
        projectSubtitleArea(
          area: (left: 0, top: 0, right: 40, bottom: 40),
          original: const Size(200, 200),
          decoded: const Size(100, 100),
          crop: const Rect.fromLTRB(10, 10, 90, 90),
          destination: const Rect.fromLTWH(20, 30, 160, 160),
          split: false,
          invert: false,
        ),
        [const Rect.fromLTRB(20, 30, 40, 50)],
      );
    },
  );

  testWidgets(
    'search scrolls the lower bubble into view and original mode removes text',
    (tester) async {
      final index = _index();
      final display = SubtitleDisplay((_) async => index);
      await display.ensure('one');
      final scroll = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 192,
                height: 200,
                child: SubtitleScope(
                  notifier: display,
                  child: SingleChildScrollView(
                    controller: scroll,
                    child: const SizedBox(
                      width: 192,
                      height: 768,
                      child: PageSubtitleLayer(
                        chapter: 'one',
                        imageKey: 'file://dawn.png',
                        original: Size(192, 768),
                        decoded: Size(192, 768),
                        crop: Rect.fromLTWH(0, 0, 192, 768),
                        fit: BoxFit.contain,
                        alignment: Alignment.center,
                        split: false,
                        invert: false,
                        scale: 1,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final query = index.search('日出', 'zh').single;
      expect(scroll.offset, 0);
      display.highlight(query);
      await tester.pump();
      await tester.pump();
      expect(scroll.offset, greaterThan(500));
      final viewport = tester.getRect(find.byType(SingleChildScrollView));
      expect(viewport.contains(tester.getCenter(find.text('入口日出'))), isTrue);
      await tester.pump(const Duration(seconds: 4));
      display.configure(false, null);
      await tester.pump();
      expect(find.text('入口日出'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      display.dispose();
      scroll.dispose();
    },
  );

  test(
    'discarding a revision invalidates a pending index and navigation',
    () async {
      final pending = Completer<ChapterSubtitleIndex>();
      final display = SubtitleDisplay((_) => pending.future);
      final request = display.ensure('one');
      final token = display.startNavigation();
      display.refresh();
      pending.complete(_index());
      await request;
      expect(display.indexes, isEmpty);
      expect(display.acceptsNavigation(token), isFalse);
      display.dispose();
    },
  );
}
