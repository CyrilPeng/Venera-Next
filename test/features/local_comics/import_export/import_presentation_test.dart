import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/local_comics/import_export/import_comic.dart';
import 'package:venera_next/features/local_comics/import_export/import_presentation.dart';
import 'package:venera_next/features/local_comics/import_export/pdf_import_batch.dart';
import 'package:venera_next/features/local_comics/import_export/pdf_import_tasks.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/file_interaction.dart';

class _Selection extends FileSelection {
  _Selection() : super.androidDocument(uri: 'test.pdf', name: 'test.pdf');
  int disposed = 0;
  @override
  Future<File> prepare() async => File(name);
  @override
  Future<void> dispose() async {
    disposed++;
  }
}

void main() {
  const presentation = ImportComicPresentation();
  Future<void> host(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(navigatorKey: App.rootNavigatorKey, home: const Scaffold()),
  );

  testWidgets('import completion and presentation tolerate absent root', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox());
    presentation.showMessage(message: 'Completed');
    expect(presentation.showLoading(), isNull);
    expect(await const ImportComic().registerComics({}, false), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('loading cleanup survives unmount and uses the new root later', (
    tester,
  ) async {
    await host(tester);
    var cancelled = 0;
    final controller = presentation.showLoading(onCancel: () => cancelled++);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpWidget(const SizedBox());
    expect(controller!.closed, isTrue);
    expect(cancelled, 1);
    controller.setMessage('Late progress');
    controller.setProgress(1);
    controller.close();
    presentation.showMessage(message: 'Late completion');
    await host(tester);
    final next = presentation.showLoading(
      message: 'New import',
      allowCancel: false,
    );
    await tester.pump();
    expect(find.text('New import'), findsOneWidget);
    next!.close();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final visible in [false, true]) {
    testWidgets(
      'PDF view finishes without cancelling app task; visible=$visible',
      (tester) async {
        final tasks = PdfImportTasks();
        final gate = Completer<void>();
        final file = _Selection();
        final task = tasks.add(
          files: [file],
          batch: PdfImportBatch(
            containsTitle: (_) => false,
            importFile: (_, title, progress, cancellation) async {
              await gate.future;
              cancellation.throwIfCancelled();
            },
          ),
        );
        addTearDown(tasks.dispose);
        if (visible) {
          await host(tester);
        } else {
          await tester.pumpWidget(const SizedBox());
        }
        var viewClosed = false;
        final view = presentation
            .showPdfTask(task)
            .then((_) => viewClosed = true);
        await tester.pump();
        if (visible) {
          await tester.pump(const Duration(milliseconds: 400));
          expect(viewClosed, isFalse);
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
        }
        await tester.pump();
        expect(viewClosed, isTrue);
        await view;
        expect(viewClosed, isTrue);
        expect(task.isFinished, isFalse);
        expect(task.isCancelling, isFalse);
        gate.complete();
        await tester.pump();
        expect(task.isFinished, isTrue);
        final result = await task.done;
        expect(result.count(PdfImportStatus.imported), 1);
        expect(file.disposed, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
