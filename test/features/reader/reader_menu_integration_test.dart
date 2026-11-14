import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart'
    show ComicSourceManager;
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/features/reader/auto_reading.dart';
import 'package:venera_next/features/reader/continuous_view.dart';
import 'package:venera_next/features/reader/gallery_view.dart';
import 'package:venera_next/features/reader/reader_page.dart';
import 'package:venera_next/features/reader/scaffold.dart';
import 'package:venera_next/features/reader/images_host.dart';
import 'package:venera_next/routing/settings.dart' show ReaderSettings;
import 'package:venera_next/routing/app_navigation.dart';
import 'package:venera_next/foundation/appdata.dart';

import 'support/reader_integration_fixture.dart';

void main() {
  setUpReaderIntegration();

  testWidgets('captured gallery shell callbacks ignore unmounted owner', (
    tester,
  ) async {
    final fixture = await ReaderIntegrationFixture.create(tester);
    try {
      await fixture.mount(tester, pushed: false);
      final view = tester.widget<ReaderGalleryView>(
        find.byType(ReaderGalleryView),
      );
      await tester.pumpWidget(const SizedBox());
      view.onCollectImage();
      view.onPageReported(true, true);
      view.onChapterChanged();
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets('reader context menu can open settings for its original route', (
    tester,
  ) async {
    final fixture = await ReaderIntegrationFixture.create(tester);
    try {
      await fixture.mount(tester, pushed: false);
      await tester.tapAt(
        tester.getCenter(find.byType(ReaderGalleryView)),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsOneWidget);
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderSettings), findsOneWidget);
      expect(fixture.readerKey.currentState, isNotNull);
    } finally {
      await fixture.dispose(tester);
    }
  });

  for (final change in ['chapter', 'viewport', 'settings', 'source', 'hold']) {
    testWidgets('reader context menu retires automatically on $change change', (
      tester,
    ) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      var source = ReaderFixtureCommentSource();
      final restore = readerFixtureCommentRegistry(() => source);
      final saving = Completer<void>();
      try {
        await fixture.mount(
          tester,
          pushed: false,
          chapters: const ComicChapters({'one': 'One', 'two': 'Two'}),
        );
        final reader = fixture.readerKey.currentState!;
        if (change == 'hold') {
          // Isolate preparation from the normal menu-first window back action.
          reader.disposeReaderWindow();
          await tester.pumpAndSettle();
        }
        await tester.tapAt(
          tester.getCenter(find.byType(ReaderGalleryView)),
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        expect(find.text('Settings'), findsOneWidget);
        switch (change) {
          case 'chapter':
            expect(reader.toChapter(2), isTrue);
          case 'viewport':
            reader.mode = ReaderMode.continuousTopToBottom;
            reader.update();
          case 'settings':
            appdata.settings['enableTapToTurnPages'] = false;
            reader.update();
          case 'source':
            source = ReaderFixtureCommentSource();
            ComicSourceManager.current!.notifyStateChange();
          case 'hold':
            fixture.history.onProgress = (_) => saving.future;
            fixture.closeWindow(tester);
            expect(fixture.frame.isClosing, isTrue);
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        expect(find.text('Settings'), findsNothing);
        expect(find.byType(ReaderSettings), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        if (!saving.isCompleted) saving.complete();
        await tester.pump();
        await fixture.dispose(tester);
        restore();
      }
    });
  }

  testWidgets(
    'removing reader clears its context menu and preserves the cover route',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      try {
        await fixture.mount(tester, pushed: true);
        final reader = fixture.readerKey.currentState!;
        final route = ModalRoute.of(reader.context)!;
        await tester.tapAt(
          tester.getCenter(find.byType(ReaderGalleryView)),
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        expect(find.text('Settings'), findsOneWidget);
        final navigator = appNavigation.rootNavigatorKey.currentState!;
        unawaited(
          navigator.push<void>(
            MaterialPageRoute(
              builder: (_) => const Scaffold(body: Text('Menu cover')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        navigator.removeRoute(route);
        await tester.pumpAndSettle();
        expect(find.text('Menu cover'), findsOneWidget);
        navigator.pop();
        await tester.pumpAndSettle();
        expect(find.text('Library home'), findsOneWidget);
        expect(find.text('Settings'), findsNothing);
        expect(navigator.canPop(), isFalse);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    },
  );

  testWidgets('delayed reader tap is retired when its page is removed', (
    tester,
  ) async {
    final fixture = await ReaderIntegrationFixture.create(tester);
    try {
      appdata.settings['enableDoubleTapToZoom'] = true;
      await fixture.mount(tester, pushed: false);
      await tester.tapAt(tester.getCenter(find.byType(ReaderGalleryView)));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets('delayed reader tap cannot open menus for a replaced chapter', (
    tester,
  ) async {
    final fixture = await ReaderIntegrationFixture.create(tester);
    try {
      appdata.settings['enableDoubleTapToZoom'] = true;
      await fixture.mount(tester, pushed: false);
      await tester.tapAt(tester.getCenter(find.byType(ReaderGalleryView)));
      fixture.readerKey.currentState!.controller.restoreChapter(2);
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester.state<ReaderScaffoldState>(find.byType(ReaderScaffold)).isOpen,
        isFalse,
      );
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets('delayed reader long press cannot act on a replaced chapter', (
    tester,
  ) async {
    final fixture = await ReaderIntegrationFixture.create(tester);
    try {
      appdata.settings['longPressAction'] = 'autoReading';
      await fixture.mount(tester, pushed: false);
      final reader = fixture.readerKey.currentState!;
      var becameActive = false;
      void recordAutomaticReading() {
        becameActive |= reader.autoReading.isActive;
      }

      reader.autoReading.addListener(recordAutomaticReading);
      final pointer = await tester.startGesture(
        tester.getCenter(find.byType(ReaderGalleryView)),
      );
      reader.controller.restoreChapter(2);
      await tester.pump(const Duration(milliseconds: 300));
      await pointer.up();
      expect(reader.autoReading.isActive, isFalse);
      expect(becameActive, isFalse);
      reader.autoReading.removeListener(recordAutomaticReading);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets(
    'changing mode during an active gesture releases its pause safely',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      try {
        await fixture.mount(tester, pushed: false);
        final reader = fixture.readerKey.currentState!;
        reader.autoReading.start();
        final pointer = await tester.startGesture(
          tester.getCenter(find.byType(ReaderGalleryView)),
        );
        expect(reader.autoReading.status, AutoReadingStatus.paused);
        await tester.pump(const Duration(milliseconds: 300));
        reader.mode = ReaderMode.continuousTopToBottom;
        reader.update();
        await tester.pump();
        expect(
          reader.autoReading.status,
          isIn([AutoReadingStatus.running, AutoReadingStatus.waiting]),
        );
        expect(tester.takeException(), isNull);
        reader.autoReading.stop();
        await pointer.up();
      } finally {
        await fixture.dispose(tester);
      }
    },
  );

  testWidgets(
    'sidebar pauses are independent and release only their own reason',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      try {
        await fixture.mount(tester, pushed: false);
        final reader = fixture.readerKey.currentState!;
        reader.autoReading.start();
        final first = reader.acquireAutomaticReadingPause();
        final second = reader.acquireAutomaticReadingPause();
        reader.autoReading.pause('external', true);
        first();
        first();
        expect(reader.autoReading.status, AutoReadingStatus.paused);
        second();
        expect(reader.autoReading.status, AutoReadingStatus.paused);
        reader.autoReading.pause('external', false);
        expect(reader.autoReading.status, AutoReadingStatus.running);
        final lateRelease = reader.acquireAutomaticReadingPause();
        await tester.pumpWidget(const SizedBox());
        lateRelease();
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    },
  );

  testWidgets(
    'diagnostics confirms after benign reader updates and stops in background',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      try {
        await fixture.mount(tester, pushed: false, withWindow: false);
        final reader = fixture.readerKey.currentState!;
        final scaffold = tester.state<ReaderScaffoldState>(
          find.byType(ReaderScaffold),
        );
        scaffold.openOrClose();
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Reading diagnostics'));
        await tester.pumpAndSettle();
        expect(reader.readerDiagnostics.isRecording, isFalse);
        reader.update();
        await tester.pump();
        await tester.tap(find.text('Start new 45-second capture'));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 400));
        expect(reader.readerDiagnostics.isRecording, isTrue);
        expect(find.byTooltip('Stop and review'), findsOneWidget);
        reader.didChangeAppLifecycleState(AppLifecycleState.inactive);
        reader.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await tester.pump();
        expect(reader.readerDiagnostics.isRecording, isFalse);
        expect(
          jsonDecode(reader.readerDiagnostics.exportJson())['stopReason'],
          'background',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    },
  );

  for (final interruption in ['background', 'mode']) {
    testWidgets(
      'diagnostics confirmation cannot restart after $interruption interruption',
      (tester) async {
        final fixture = await ReaderIntegrationFixture.create(tester);
        try {
          await fixture.mount(tester, pushed: false, withWindow: false);
          final reader = fixture.readerKey.currentState!;
          final opening = reader.openDiagnostics();
          await tester.pumpAndSettle();
          if (interruption == 'background') {
            reader.didChangeAppLifecycleState(AppLifecycleState.inactive);
            reader.didChangeAppLifecycleState(AppLifecycleState.resumed);
          } else {
            reader.applyReadingMode(ReaderMode.galleryRightToLeft);
            reader.applyReadingMode(ReaderMode.galleryLeftToRight);
          }
          await tester.tap(find.text('Start new 45-second capture'));
          await tester.pumpAndSettle();
          await tester.pump(const Duration(milliseconds: 400));
          await opening;
          expect(reader.readerDiagnostics.isRecording, isFalse);
          expect(reader.readerDiagnostics.hasCapture, isFalse);
          expect(tester.takeException(), isNull);
        } finally {
          await fixture.dispose(tester);
        }
      },
    );
  }

  testWidgets('moving keyboard focus into the menu stops held gallery paging', (
    tester,
  ) async {
    final fixture = await ReaderIntegrationFixture.create(tester);
    try {
      appdata.settings['enablePageAnimation'] = false;
      await fixture.mount(tester, pushed: false);
      final reader = fixture.readerKey.currentState!;
      final gallery = reader.imageViewController! as GalleryModeState;
      reader.focusNode.requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      expect(gallery.keyRepeatTimer, isNotNull);
      expect(reader.page, 2);
      final shell = tester.state<ReaderScaffoldState>(
        find.byType(ReaderScaffold),
      );
      shell.openOrClose();
      await tester.pump();
      Focus.of(tester.element(find.byIcon(Icons.first_page))).requestFocus();
      await tester.pump();
      expect(gallery.keyRepeatTimer, isNull);
      await tester.pump(const Duration(milliseconds: 700));
      expect(reader.page, 2);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      shell.openOrClose();
      await tester.pumpAndSettle();
      expect(reader.focusNode.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(reader.page, 1);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets(
    'moving keyboard focus into the menu releases continuous CTRL state',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      try {
        appdata.settings['readerMode'] = ReaderMode.continuousTopToBottom.key;
        await fixture.mount(tester, pushed: false);
        final reader = fixture.readerKey.currentState!;
        final flow = reader.imageViewController! as ContinuousModeState;
        reader.focusNode.requestFocus();
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        expect(flow.isCTRLPressed, isTrue);
        final shell = tester.state<ReaderScaffoldState>(
          find.byType(ReaderScaffold),
        );
        shell.openOrClose();
        await tester.pump();
        Focus.of(tester.element(find.byIcon(Icons.first_page))).requestFocus();
        await tester.pump();
        expect(flow.isCTRLPressed, isFalse);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        shell.openOrClose();
        await tester.pumpAndSettle();
        final before = flow.scrollController.offset;
        await tester.drag(find.byType(ReaderImagesHost), const Offset(0, -200));
        await tester.pumpAndSettle();
        expect(flow.scrollController.offset, greaterThan(before));
      } finally {
        await fixture.dispose(tester);
      }
    },
  );
}
