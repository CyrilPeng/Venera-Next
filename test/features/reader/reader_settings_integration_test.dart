import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart' as archive;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/features/local_comics/import_export/cbz.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/features/reader/brightness.dart';
import 'package:venera_next/features/reader/comic_image.dart';
import 'package:venera_next/features/reader/continuous_view.dart';
import 'package:venera_next/features/reader/display_image_provider.dart';
import 'package:venera_next/features/settings/setting_components.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/features/reader/reader_page.dart';
import 'package:venera_next/features/reader/scaffold.dart';
import 'package:venera_next/features/reader/chapters.dart';
import 'package:venera_next/features/reader/settings_panel.dart';
import 'package:venera_next/routing/settings.dart' show ReaderSettings;
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/app_data_operations.dart';

import 'support/reader_integration_fixture.dart';

void main() {
  setUpReaderIntegration();

  testWidgets(
    'enabling crop in an imported ZIP waterfall applies to every page',
    (tester) async {
      tester.view.physicalSize = const Size(400, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = await ReaderIntegrationFixture.create(
        tester,
        imageCount: 8,
      );
      try {
        final page = img.Image(width: 100, height: 160, numChannels: 4);
        img.fill(page, color: img.ColorRgba8(255, 255, 255, 255));
        img.fillRect(
          page,
          x1: 10,
          y1: 0,
          x2: 87,
          y2: 159,
          color: img.ColorRgba8(32, 64, 96, 255),
        );
        final bytes = img.encodePng(page);
        final contents = archive.Archive();
        for (var i = 1; i <= 8; i++) {
          contents.addFile(
            archive.ArchiveFile('wrapped/$i.png', bytes.length, bytes),
          );
        }
        final input = File('${fixture.directory.path}/crop-pages.zip')
          ..writeAsBytesSync(archive.ZipEncoder().encodeBytes(contents));
        final imported = (await tester.runAsync(
          () => CBZ.import(
            input,
            registerComic: (comic) => LocalManager().add(comic, comic.id),
          ),
        ))!;
        appdata.settings['readerMode'] = ReaderMode.waterfallTopToBottom.key;
        appdata.settings['readerSideMargin'] = 0;
        appdata.settings['cropWhiteBorders'] = false;
        await fixture.mount(
          tester,
          pushed: false,
          comicId: imported.id,
          chapters: imported.chapters,
          savedHistory: readerResumeHistory(maxPage: 8)..id = imported.id,
        );
        final shell = tester.state<ReaderScaffoldState>(
          find.byType(ReaderScaffold),
        );
        shell.openSetting();
        await tester.pumpAndSettle();
        final cropSetting = find.byWidgetPredicate(
          (widget) =>
              widget is SwitchSetting &&
              widget.settingKey == 'cropWhiteBorders',
        );
        await tester.scrollUntilVisible(
          cropSetting,
          250,
          scrollable: find
              .descendant(
                of: find.byType(ReaderSettingsPanel),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.tap(
          find.descendant(of: cropSetting, matching: find.byType(Switch)),
        );
        await pumpReaderUntil(
          tester,
          () =>
              fixture.readerKey.currentState!.preferences.cropWhiteBorders &&
              !tester
                  .state<SettingsSaveState<SwitchSetting>>(cropSetting)
                  .savingSettings,
        );
        Navigator.of(tester.element(cropSetting)).pop();
        await pumpReaderUntil(
          tester,
          () => find.byType(ReaderSettingsPanel).evaluate().isEmpty,
        );
        if (shell.isOpen) shell.openOrClose();
        await tester.pump();
        final scrollable = find
            .descendant(
              of: find.byType(ReaderContinuousView),
              matching: find.byType(Scrollable),
            )
            .first;
        for (var i = 1; i <= 8; i++) {
          final image = find.byWidgetPredicate(
            (widget) =>
                widget is ComicImage &&
                widget.image is ReaderDisplayImageProvider &&
                (widget.image as ReaderDisplayImageProvider).image.imageKey
                    .replaceAll('\\', '/')
                    .endsWith('/$i.png'),
          );
          await tester.scrollUntilVisible(image, 250, scrollable: scrollable);
          await pumpReaderUntil(tester, () {
            final size = tester.getSize(image);
            return (size.height / size.width - 160 / 82).abs() < 0.001;
          });
        }
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    },
  );

  testWidgets('current page keeps the saved dimming value after preview ends', (
    tester,
  ) async {
    final fixture = await ReaderIntegrationFixture.create(tester);
    final gate = Completer<void>();
    Future<void>? exclusive;
    try {
      appdata.settings['readerBrightnessEnabled'] = true;
      appdata.settings['readerBrightness'] = 60;
      await fixture.mount(tester, pushed: false);
      final reader = fixture.readerKey.currentState!;
      final viewport = reader.imageViewController;
      final shell = tester.state<ReaderScaffoldState>(
        find.byType(ReaderScaffold),
      );
      shell.openOrClose();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Reader brightness'));
      await tester.pumpAndSettle();
      exclusive = AppDataOperations.instance.run(() => gate.future);
      tester.widget<Slider>(find.byType(Slider).last).onChanged!(30);
      await tester.pump();
      expect(
        tester
            .widget<ReaderBrightnessOverlay>(
              find.byType(ReaderBrightnessOverlay),
            )
            .brightness,
        30,
      );
      gate.complete();
      await pumpReaderUntil(
        tester,
        () =>
            reader.preferences.readerBrightness == 30 &&
            tester.widget<Slider>(find.byType(Slider).last).value == 30,
      );
      var saved = false;
      final saving = appdata.saveData(false).then((_) => saved = true);
      await pumpReaderUntil(tester, () => saved);
      await saving;
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ReaderBrightnessOverlay>(
              find.byType(ReaderBrightnessOverlay),
            )
            .brightness,
        30,
      );
      expect(reader.imageViewController, same(viewport));
      expect(reader.page, 1);
      expect(tester.takeException(), isNull);
    } finally {
      if (!gate.isCompleted) gate.complete();
      await tester.pump();
      if (exclusive != null) await tester.runAsync(() => exclusive!);
      await fixture.dispose(tester);
    }
  });

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
