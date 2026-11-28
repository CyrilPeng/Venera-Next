import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/features/reader/comic_image.dart';
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
    'TV directional controls open and dismiss chapter subtitles from the reader',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      try {
        appdata.settings['externalSubtitles'] = true;
        await fixture.mount(tester, pushed: false, tvNavigation: true);
        final reader = fixture.readerKey.currentState!;
        Future<void> press(LogicalKeyboardKey key) async {
          await tester.sendKeyEvent(key);
          await tester.pumpAndSettle();
        }

        if (!reader.scaffoldKey.currentState!.isOpen) {
          await press(LogicalKeyboardKey.select);
        }
        expect(reader.scaffoldKey.currentState!.isOpen, isTrue);
        await press(LogicalKeyboardKey.arrowUp);
        bool onSubtitles() =>
            FocusManager.instance.primaryFocus?.context
                ?.findAncestorWidgetOfExactType<IconButton>()
                ?.tooltip ==
            'Chapter subtitles';
        for (var step = 0; step < 8 && !onSubtitles(); step++) {
          await press(LogicalKeyboardKey.arrowRight);
        }
        expect(onSubtitles(), isTrue);
        await press(LogicalKeyboardKey.select);
        expect(
          find.widgetWithText(AlertDialog, 'Chapter subtitles'),
          findsOneWidget,
        );
        await press(LogicalKeyboardKey.escape);
        expect(find.byType(AlertDialog), findsNothing);
        expect(reader.page, 1);
      } finally {
        await fixture.dispose(tester);
      }
    },
  );
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
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        for (final size in [const Size(720, 560), const Size(1040, 680)]) {
          tester.view.physicalSize = size;
          await tester.pumpAndSettle();
          final subtitle = find.text('山脚下');
          final image = find.descendant(
            of: find.ancestor(of: subtitle, matching: find.byType(ComicImage)),
            matching: find.byType(RawImage),
          );
          final box = tester.renderObject<RenderBox>(image);
          final painted = tester
              .widget<RawImage>(image)
              .alignment
              .resolve(TextDirection.ltr)
              .inscribe(
                applyBoxFit(
                  BoxFit.contain,
                  const Size(192, 256),
                  box.size,
                ).destination,
                Offset.zero & box.size,
              );
          // Centre of the fixture's source rectangle [52, 32, 139, 119].
          final expected =
              painted.topLeft +
              Offset(painted.width * 95.5 / 192, painted.height * 75.5 / 256);
          final actual = box.globalToLocal(tester.getCenter(subtitle));
          expect((actual - expected).distance, lessThan(1));
        }
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
