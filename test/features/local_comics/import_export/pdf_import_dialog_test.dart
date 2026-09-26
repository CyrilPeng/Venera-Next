import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/local_comics/import_export/import_export.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/translations.dart';

class _Selection extends FileSelection {
  _Selection(String name) : super.androidDocument(uri: name, name: name);

  @override
  Future<File> prepare() async => File(name);

  @override
  Future<void> dispose() async {}
}

Future<BuildContext> _pumpHost(
  WidgetTester tester, {
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) async {
  late BuildContext dialogContext;
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: true,
        ),
        child: child!,
      ),
      home: Builder(
        builder: (context) {
          dialogContext = context;
          return const Scaffold(body: SizedBox.shrink());
        },
      ),
    ),
  );
  return dialogContext;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PdfImportTasks tasks;

  Future<PdfImportBatchResult?> showImport({
    required BuildContext context,
    required List<FileSelection> files,
    required PdfImportBatch batch,
  }) => showPdfImportDialog(
    context: context,
    task: tasks.add(files: files, batch: batch),
    tasks: tasks,
  );

  setUp(() async {
    tasks = PdfImportTasks();
    addTearDown(tasks.dispose);
    final language = appdata.settings['language'];
    final muted = Log.isMuted;
    appdata.settings['language'] = 'en-US';
    Log.isMuted = true;
    await AppTranslation.init();
    addTearDown(() {
      appdata.settings['language'] = language;
      Log.isMuted = muted;
    });
  });

  testWidgets('shows two-level progress and waits for safe cancellation', (
    tester,
  ) async {
    final gate = Completer<void>();
    final context = await _pumpHost(tester);
    final result = showImport(
      context: context,
      files: [_Selection('Volume 1.pdf'), _Selection('Volume 2.pdf')],
      batch: PdfImportBatch(
        containsTitle: (_) => false,
        importFile: (_, title, onProgress, cancellation) async {
          onProgress(1, 3);
          await gate.future;
          cancellation.throwIfCancelled();
        },
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('File 1 of 2'), findsOneWidget);
    expect(find.text('Volume 1.pdf'), findsOneWidget);
    expect(find.text('Pages: 1/3'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNWidgets(2));

    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(find.text('Cancelling import'), findsOneWidget);
    expect(find.text('Not imported: 2'), findsNothing);
    gate.complete();
    await tester.pumpAndSettle();

    expect(find.text('PDF import cancelled'), findsOneWidget);
    expect(find.text('Not imported: 2'), findsOneWidget);
    expect(find.text('Failed: 0'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect((await result)!.count(PdfImportStatus.cancelled), 2);
  });

  testWidgets(
    'back hides progress, reopening does not restart, and completion keeps the reader open',
    (tester) async {
      final gate = Completer<void>();
      final context = await _pumpHost(tester);
      var calls = 0;
      final result = showImport(
        context: context,
        files: [_Selection('Volume.pdf')],
        batch: PdfImportBatch(
          containsTitle: (_) => false,
          importFile: (_, title, onProgress, cancellation) async {
            calls++;
            onProgress(1, 3);
            await gate.future;
            cancellation.throwIfCancelled();
          },
        ),
      );
      await tester.pumpAndSettle();
      final task = tasks.tasks.single;
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(PdfImportDialog), findsNothing);
      expect(task.isCancelling, isFalse);
      expect(await result, isNull);

      unawaited(showPdfImportTasksDialog(context: context, tasks: tasks));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Volume.pdf'));
      await tester.pumpAndSettle();
      expect(find.byType(PdfImportDialog), findsOneWidget);
      expect(calls, 1);
      await tester.tap(find.text('Run in background'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Reading another comic')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Reading another comic'), findsOneWidget);
      expect(find.byType(PdfImportDialog), findsNothing);
      expect(task.result!.count(PdfImportStatus.imported), 1);
      expect(calls, 1);
      Navigator.of(context).pop();
      await tester.pumpAndSettle();

      unawaited(showPdfImportTasksDialog(context: context, tasks: tasks));
      await tester.pumpAndSettle();
      expect(find.textContaining('Imported: 1'), findsOneWidget);
      await tester.tap(find.text('Volume.pdf'));
      await tester.pumpAndSettle();
      expect(find.text('Imported: 1'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear completed tasks'));
      await tester.pumpAndSettle();
      expect(find.text('No import tasks'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'closing the summary still returns successfully imported comics',
    (tester) async {
      final context = await _pumpHost(tester);
      final result = showImport(
        context: context,
        files: [_Selection('Volume.pdf')],
        batch: PdfImportBatch(
          containsTitle: (_) => false,
          importFile: (_, title, onProgress, cancellation) async {},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Imported: 1'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect((await result)!.count(PdfImportStatus.imported), 1);
    },
  );

  for (final size in [
    const Size(375, 667),
    const Size(667, 375),
    const Size(1200, 800),
  ]) {
    for (final language in ['en-US', 'zh-CN']) {
      testWidgets(
        'progress and results fit $size in $language at large text size',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          appdata.settings['language'] = language;
          final gate = Completer<void>();
          final context = await _pumpHost(
            tester,
            textScale: 2,
            brightness: Brightness.dark,
          );
          final result = showImport(
            context: context,
            files: [
              _Selection('${'LongVolumeName' * 10}.pdf'),
              _Selection('Broken.pdf'),
            ],
            batch: PdfImportBatch(
              containsTitle: (_) => false,
              importFile: (_, title, onProgress, cancellation) async {
                onProgress(1, 10);
                await gate.future;
                if (title == 'Broken') throw const PdfPageRenderException(2);
              },
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(tester.takeException(), isNull);
          gate.complete();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('Imported: @a'.tlParams({'a': 1})), findsOneWidget);
          expect(find.text('Failed: @a'.tlParams({'a': 1})), findsOneWidget);
          await tester.ensureVisible(find.text('OK'.tl));
          await tester.tap(find.text('OK'.tl));
          await tester.pumpAndSettle();
          expect((await result)!.count(PdfImportStatus.imported), 1);
          unawaited(showPdfImportTasksDialog(context: context, tasks: tasks));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
        },
      );
    }
  }
}
