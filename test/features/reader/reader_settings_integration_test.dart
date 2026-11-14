import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/features/reader/reader_page.dart';
import 'package:venera_next/features/reader/scaffold.dart';
import 'package:venera_next/features/reader/chapters.dart';
import 'package:venera_next/features/reader/settings_panel.dart';
import 'package:venera_next/routing/settings.dart' show ReaderSettings;
import 'package:venera_next/foundation/appdata.dart';

import 'support/reader_integration_fixture.dart';

void main() {
  setUpReaderIntegration();

  testWidgets('settings panel applies mode to its original reader', (
    tester,
  ) async {
    final fixture = await ReaderIntegrationFixture.create(tester);
    try {
      await fixture.mount(tester, pushed: false);
      final reader = fixture.readerKey.currentState!;
      final shell = tester.state<ReaderScaffoldState>(
        find.byType(ReaderScaffold),
      );
      shell.openSetting();
      await tester.pumpAndSettle();
      final panel = tester.widget<ReaderSettingsPanel>(
        find.byType(ReaderSettingsPanel),
      );
      final settings = tester.widget<ReaderSettings>(
        find.byType(ReaderSettings),
      );
      expect(panel.work, same(reader.imageWork));
      expect(settings.comicId, 'book');
      expect(settings.comicSource, 'local');
      appdata.settings['readerMode'] = ReaderMode.continuousTopToBottom.key;
      settings.onChanged!('readerMode');
      await tester.pumpAndSettle();
      expect(reader.mode, ReaderMode.continuousTopToBottom);
      expect(settings.currentReaderMode!(), reader.mode.key);
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets('chapter drawer routes repeated IDs to their flattened chapter', (
    tester,
  ) async {
    final fixture = await ReaderIntegrationFixture.create(tester);
    try {
      await fixture.mount(
        tester,
        pushed: true,
        chapters: const ComicChapters.grouped({
          'First volume': {'one': 'First chapter'},
          'Second volume': {'one': 'Second chapter'},
        }),
      );
      final shell = tester.state<ReaderScaffoldState>(
        find.byType(ReaderScaffold),
      );
      shell.openChapterDrawer();
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.download_done_rounded), findsOneWidget);
      await tester.tap(find.text('Second volume'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Second chapter'));
      await tester.pump();
      expect(fixture.readerKey.currentState!.chapter, 2);
      expect(find.byType(ReaderChaptersView), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets(
    'old menu cannot select replacement chapter data or dismiss new menu',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      try {
        const original = ComicChapters.grouped({
          'Volume': {'one': 'Original chapter'},
        });
        const replacement = ComicChapters.grouped({
          'Volume': {'one': 'Replacement chapter'},
        });
        await fixture.mount(tester, pushed: false, chapters: original);
        var shell = tester.state<ReaderScaffoldState>(
          find.byType(ReaderScaffold),
        );
        shell.openChapterDrawer();
        await tester.pumpAndSettle();
        final old = tester.widget<ReaderChaptersView>(
          find.byType(ReaderChaptersView),
        );
        final request = fixture.readerKey.currentState!.createChapterMenu()!;
        await fixture.mount(tester, pushed: false, chapters: replacement);
        expect(request.select(1), isFalse);
        old.onSelect(1);
        await tester.pumpAndSettle();
        shell = tester.state<ReaderScaffoldState>(find.byType(ReaderScaffold));
        shell.openChapterDrawer();
        await tester.pumpAndSettle();
        old.onSelect(1);
        old.onClose();
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byType(ReaderChaptersView),
            matching: find.text('Replacement chapter'),
          ),
          findsOneWidget,
        );
        expect(fixture.readerKey.currentState!.chapter, 1);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    },
  );

  testWidgets('chapter requests reject mutated maps and final session close', (
    tester,
  ) async {
    final fixture = await ReaderIntegrationFixture.create(tester);
    final registry = SelectionTaskRegistry();
    try {
      final chapters = {'one': 'Original chapter'};
      await fixture.mount(
        tester,
        pushed: false,
        withWindow: false,
        registry: registry,
        chapters: ComicChapters(chapters),
      );
      final reader = fixture.readerKey.currentState!;
      final original = reader.createChapterMenu()!;
      chapters['one'] = 'Edited chapter';
      expect(original.select(1), isFalse);
      final current = reader.createChapterMenu()!;
      final closing = registry.closeAndWait();
      expect(reader.createChapterMenu(), isNull);
      expect(current.select(1), isFalse);
      await tester.pump();
      await closing;
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });
}
