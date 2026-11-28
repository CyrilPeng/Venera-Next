import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/features/reader/subtitles/document.dart';
import 'package:venera_next/features/reader/subtitles/overlay.dart';
import 'package:venera_next/features/reader/subtitles/store.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:xml/xml.dart';

import 'support/reader_integration_fixture.dart';

void main() {
  setUpReaderIntegration();
  testWidgets(
    'search from an unsubtitled chapter waits for the target chapter and highlights its dialogue',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      try {
        const chapters = ComicChapters({'one': 'One', 'two': 'Two'});
        await LocalManager().add(
          LocalComic(
            id: 'book',
            title: 'Book',
            subtitle: '',
            tags: const [],
            directory: 'book',
            chapters: chapters,
            cover: '',
            comicType: ComicType.local,
            downloadedChapters: chapters.ids.toList(),
            createdAt: DateTime(2026),
          ),
          'book',
        );
        final folder = Directory('${fixture.directory.path}/comics/book/two')
          ..createSync();
        final data = File(
          'spec/comic-subtitles/fixtures/three-pages.acbf',
        ).readAsBytesSync();
        final nodes = XmlDocument.parse(
          utf8.decode(data),
        ).findAllElements('binary', namespace: subtitleNamespace);
        for (final (index, node) in nodes.indexed) {
          File(
            '${folder.path}/${index + 1}.png',
          ).writeAsBytesSync(base64Decode(node.innerText));
        }
        SubtitleStore(
          '${fixture.directory.path}/comic-subtitles.db',
        ).replace('book', 'two', null, SubtitleRevision(data, null, {}, null));
        appdata.settings['externalSubtitles'] = true;
        await fixture.mount(tester, pushed: false, chapters: chapters);
        final reader = fixture.readerKey.currentState!;
        if (!reader.scaffoldKey.currentState!.isOpen) {
          reader.scaffoldKey.currentState!.openOrClose();
        }
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Chapter subtitles'));
        await pumpReaderUntil(
          tester,
          () => tester
              .widget<SubtitleScope>(find.byType(SubtitleScope))
              .notifier!
              .indexes
              .containsKey('two'),
        );
        await tester.enterText(find.byType(TextField), '入口');
        await tester.pump();
        await tester.tap(find.textContaining('Two · Page 2'));
        await pumpReaderUntil(
          tester,
          () => reader.eid == 'two' && reader.page == 2,
        );
        expect(reader.page, 2);
        expect(
          tester
              .widget<SubtitleScope>(find.byType(SubtitleScope))
              .notifier!
              .focus
              ?.chapter,
          'two',
        );
      } finally {
        await fixture.dispose(tester);
      }
    },
  );
  testWidgets(
    'local gallery opens the saved ACBF, searches both languages and jumps to the original page',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      try {
        final acbf = File(
          'spec/comic-subtitles/fixtures/three-pages.acbf',
        ).readAsBytesSync();
        final resources = XmlDocument.parse(
          utf8.decode(acbf),
        ).findAllElements('binary', namespace: subtitleNamespace);
        final folder = Directory('${fixture.directory.path}/comics/book/one');
        for (final (index, binary) in resources.indexed) {
          File(
            '${folder.path}/${index + 1}.png',
          ).writeAsBytesSync(base64Decode(binary.innerText));
        }
        SubtitleStore(
          '${fixture.directory.path}/comic-subtitles.db',
        ).replace('book', 'one', null, SubtitleRevision(acbf, null, {}, null));
        appdata.settings['externalSubtitles'] = true;
        await fixture.mount(tester, pushed: false);
        await pumpReaderUntil(
          tester,
          () => find.text('山脚下').evaluate().isNotEmpty,
        );
        final reader = fixture.readerKey.currentState!;
        if (!reader.scaffoldKey.currentState!.isOpen) {
          reader.scaffoldKey.currentState!.openOrClose();
        }
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Chapter subtitles'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '入口');
        await tester.pump();
        final results = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(ListTile),
        );
        final hit = results.evaluate().where(
          (item) => (item.widget as ListTile).subtitle is Text,
        );
        expect(hit, hasLength(1));
        await tester.tap(
          find.descendant(of: results, matching: find.textContaining('Page 2')),
        );
        await pumpReaderUntil(tester, () => reader.page == 2);
        expect(reader.page, 2);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    },
  );
}
