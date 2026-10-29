import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/sync/comic_archive_batch.dart';
import 'package:venera_next/features/sync/comic_archive_transfer_dialog.dart';

void main() {
  ComicArchiveBatch makeBatch({
    int count = 3,
    Future<ArchiveItemState> Function(int, bool, bool Function())? action,
  }) {
    final batch = ComicArchiveBatch(
      items: [
        for (var i = 0; i < count; i++)
          ArchiveItem(
            title: 'Synthetic comic $i',
            fileName: 'Synthetic comic $i.cbz',
          ),
      ],
      action:
          action ??
          (index, retry, _) async {
            if (index == 1 && !retry) {
              throw StateError('Synthetic upload failed');
            }
            return index == 2
                ? ArchiveItemState.skipped
                : ArchiveItemState.success;
          },
      errorText: (error) => error.toString(),
    );
    return batch;
  }

  Future<void> mount(
    WidgetTester tester,
    ComicArchiveBatch batch, {
    Size size = const Size(800, 900),
    double scale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.teal,
            brightness: brightness,
          ),
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showComicArchiveTransferDialog(
                context,
                title: 'Archive to WebDAV',
                batch: batch,
              ),
              child: const Text('Open batch'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open batch'));
    await tester.pumpAndSettle();
  }

  testWidgets('results stay visible and retry only failed rows', (
    tester,
  ) async {
    // This test owns disposal because the public dialog helper also disposes.
    final calls = <int>[];
    final batch = ComicArchiveBatch(
      items: [
        for (var i = 0; i < 3; i++)
          ArchiveItem(title: 'Comic $i', fileName: '$i.cbz'),
      ],
      action: (index, retry, _) async {
        calls.add(index);
        if (index == 1 && !retry) throw StateError('Failed item');
        return ArchiveItemState.success;
      },
      errorText: (error) => error.toString(),
    );
    await mount(tester, batch);
    await tester.pump(const Duration(seconds: 12));
    expect(find.text('StateError: Failed item'), findsNothing);
    expect(find.textContaining('Failed item'), findsOneWidget);
    expect(find.text('Retry all failed items'), findsOneWidget);
    await tester.tap(find.text('Retry all failed items'));
    await tester.pumpAndSettle();
    expect(calls, [0, 1, 2, 1]);
    expect(find.text('Success: 3'), findsOneWidget);
    expect(find.text('Retry all failed items'), findsNothing);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(ComicArchiveTransferDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('single-item retry is labelled and does not retry other rows', (
    tester,
  ) async {
    final batch = makeBatch();
    await mount(tester, batch);
    final semantics = tester.ensureSemantics();
    await tester.ensureVisible(find.text('Retry this item'));
    expect(
      tester
          .getSemantics(find.widgetWithText(TextButton, 'Retry this item'))
          .label,
      contains('Retry this item'),
    );
    await tester.tap(find.text('Retry this item'));
    await tester.pumpAndSettle();
    expect(batch.count(ArchiveItemState.success), 2);
    expect(batch.count(ArchiveItemState.skipped), 1);
    expect(find.textContaining('Contents were not verified'), findsOneWidget);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'cancel blocks dismissal until native work settles and preserves pending',
    (tester) async {
      final gate = Completer<void>();
      final batch = makeBatch(
        action: (index, retry, cancelled) async {
          if (index == 0) await gate.future;
          return ArchiveItemState.success;
        },
      );
      addTearDown(batch.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ComicArchiveTransferDialog(title: 'Archive', batch: batch),
        ),
      );
      await tester.pump();
      expect(find.text('Close'), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      expect(batch.running, isTrue);
      expect(
        find.textContaining('Waiting for the current operation'),
        findsOneWidget,
      );
      gate.complete();
      await tester.pumpAndSettle();
      expect(batch.count(ArchiveItemState.pending), 2);
      expect(batch.count(ArchiveItemState.success), 1);
      expect(find.text('Continue unstarted items'), findsOneWidget);
      await tester.tap(find.text('Continue unstarted items'));
      await tester.pumpAndSettle();
      expect(batch.count(ArchiveItemState.success), 3);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('unsafe registration failures expose no retry control', (
    tester,
  ) async {
    final batch = ComicArchiveBatch(
      items: [ArchiveItem(title: 'Comic', fileName: 'Comic.cbz')],
      action: (_, _, _) async => throw const ArchiveTransferFailure(
        'Acknowledgement failed',
        retryAllowed: false,
      ),
      errorText: (error) => error.toString(),
    );
    await mount(tester, batch);
    expect(find.textContaining('Import may already be saved'), findsOneWidget);
    expect(find.text('Retry this item'), findsNothing);
    expect(find.text('Retry all failed items'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  for (final size in [
    const Size(375, 812),
    const Size(812, 375),
    const Size(1024, 768),
  ]) {
    for (final dark in [false, true]) {
      testWidgets(
        '60 results fit $size dark=$dark with large text and reduced motion',
        (tester) async {
          final batch = makeBatch(count: 60);
          await mount(
            tester,
            batch,
            size: size,
            scale: 2,
            brightness: dark ? Brightness.dark : Brightness.light,
          );
          expect(tester.takeException(), isNull);
          expect(find.text('Retry all failed items'), findsOneWidget);
          await tester.scrollUntilVisible(
            find.text('Synthetic comic 59'),
            500,
            scrollable: find.byType(Scrollable).first,
            maxScrolls: 200,
          );
          expect(find.text('Synthetic comic 59'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  for (final dark in [false, true]) {
    testWidgets('render synthetic result preview dark=$dark', (tester) async {
      final fontPath = Platform.environment['VENERA_ARCHIVE_PREVIEW_FONT'];
      if (fontPath != null) {
        await tester.runAsync(() async {
          final loader = FontLoader('ArchivePreview')
            ..addFont(File(fontPath).readAsBytes().then(ByteData.sublistView));
          await loader.load();
        });
      }
      final batch = makeBatch();
      addTearDown(batch.dispose);
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              fontFamily: fontPath == null ? null : 'ArchivePreview',
              colorScheme: ColorScheme.fromSeed(
                seedColor: Colors.teal,
                brightness: dark ? Brightness.dark : Brightness.light,
              ),
            ),
            home: ComicArchiveTransferDialog(
              title: 'Archive to WebDAV',
              batch: batch,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final output = File(
        'build/issue-126-20261029/dialog-${dark ? 'dark' : 'light'}.png',
      );
      await tester.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        await output.parent.create(recursive: true);
        await output.writeAsBytes(png!.buffer.asUint8List());
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
