import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/local_comics/import_export/import_export.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:venera_next/foundation/log.dart';

class _Selection extends FileSelection {
  _Selection(String name) : super.androidDocument(uri: name, name: name);

  int prepared = 0;
  int disposed = 0;

  @override
  Future<File> prepare() async {
    prepared++;
    return File(name);
  }

  @override
  Future<void> dispose() async => disposed++;
}

void main() {
  late PdfImportTasks tasks;
  setUp(() {
    tasks = PdfImportTasks();
    final muted = Log.isMuted;
    Log.isMuted = true;
    addTearDown(() {
      tasks.dispose();
      Log.isMuted = muted;
    });
  });

  test(
    'serializes batches and checks duplicates after preceding registration',
    () async {
      final gate = Completer<void>();
      final started = Completer<void>();
      final imported = <String>{};
      var inFlight = 0;
      var peak = 0;
      final batch = PdfImportBatch(
        containsTitle: imported.contains,
        importFile: (_, title, onProgress, cancellation) async {
          inFlight++;
          peak = inFlight > peak ? inFlight : peak;
          if (!started.isCompleted) started.complete();
          onProgress(1, 3);
          await gate.future;
          imported.add(title);
          inFlight--;
        },
      );
      final one = _Selection('Volume.pdf');
      final duplicate = _Selection('Volume.pdf');
      final two = _Selection('Next.pdf');
      final first = tasks.add(files: [one], batch: batch);
      final second = tasks.add(files: [duplicate, two], batch: batch);
      await started.future;
      expect(first.progress!.currentPage, 1);
      expect(second.isQueued, isTrue);
      expect(duplicate.prepared, 0);
      expect(two.prepared, 0);
      expect(tasks.activeCount, 2);
      tasks.clearFinished();
      expect(tasks.tasks, hasLength(2));
      gate.complete();
      await first.done;
      final result = await second.done;
      expect(peak, 1);
      expect(result.count(PdfImportStatus.skipped), 1);
      expect(result.count(PdfImportStatus.imported), 1);
      expect(duplicate.prepared, 0);
      expect([one.disposed, duplicate.disposed, two.disposed], [1, 1, 1]);
      expect(tasks.activeCount, 0);
      expect(tasks.tasks, hasLength(2));
      tasks.clearFinished();
      expect(tasks.tasks, isEmpty);
    },
  );

  test(
    'queued cancellation releases selections without preparing or waiting',
    () async {
      final gate = Completer<void>();
      final started = Completer<void>();
      var calls = 0;
      final batch = PdfImportBatch(
        containsTitle: (_) => false,
        importFile: (_, title, onProgress, cancellation) async {
          calls++;
          if (!started.isCompleted) started.complete();
          await gate.future;
        },
      );
      final first = tasks.add(files: [_Selection('First.pdf')], batch: batch);
      final selection = _Selection('Queued.pdf');
      final queued = tasks.add(files: [selection], batch: batch);
      await started.future;
      tasks.cancel(queued);
      final result = await queued.done;
      expect(first.isFinished, isFalse);
      expect(result.count(PdfImportStatus.cancelled), 1);
      expect(selection.prepared, 0);
      expect(selection.disposed, 1);
      expect(calls, 1);
      tasks.clearFinished();
      expect(tasks.tasks, [first]);
      gate.complete();
      await first.done;
    },
  );

  test(
    'active cancellation waits for cleanup then starts the next batch',
    () async {
      final gate = Completer<void>();
      final started = Completer<void>();
      final firstFiles = [_Selection('Active.pdf'), _Selection('Later.pdf')];
      final first = tasks.add(
        files: firstFiles,
        batch: PdfImportBatch(
          containsTitle: (_) => false,
          importFile: (_, title, onProgress, cancellation) async {
            started.complete();
            await gate.future;
            cancellation.throwIfCancelled();
          },
        ),
      );
      var nextStarted = false;
      final second = tasks.add(
        files: [_Selection('Next.pdf')],
        batch: PdfImportBatch(
          containsTitle: (_) => false,
          importFile: (_, title, onProgress, cancellation) async {
            expect(firstFiles.every((file) => file.disposed == 1), isTrue);
            nextStarted = true;
          },
        ),
      );
      await started.future;
      tasks.cancel(first);
      tasks.cancel(first);
      expect(first.isCancelling, isTrue);
      expect(first.isFinished, isFalse);
      expect(nextStarted, isFalse);
      gate.complete();
      expect((await first.done).count(PdfImportStatus.cancelled), 2);
      expect((await second.done).count(PdfImportStatus.imported), 1);
      expect(firstFiles.last.prepared, 0);
    },
  );

  test(
    'failed batch retains errors and does not block later batches',
    () async {
      final first = tasks.add(
        files: [_Selection('Broken.pdf')],
        batch: PdfImportBatch(
          containsTitle: (_) => false,
          importFile: (_, title, onProgress, cancellation) async {
            throw const FormatException('Bad PDF');
          },
        ),
      );
      final second = tasks.add(
        files: [_Selection('Next.pdf')],
        batch: PdfImportBatch(
          containsTitle: (_) => false,
          importFile: (_, title, onProgress, cancellation) async {},
        ),
      );
      expect((await first.done).items.single.error, isA<FormatException>());
      expect((await second.done).count(PdfImportStatus.imported), 1);
      expect(tasks.tasks, hasLength(2));
    },
  );
}
