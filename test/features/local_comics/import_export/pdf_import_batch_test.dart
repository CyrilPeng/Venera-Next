import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/local_comics/import_export/import_export.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:venera_next/foundation/log.dart';

class _Selection extends FileSelection {
  _Selection(
    String name, {
    String? identifier,
    this.prepareError,
    this.releaseError,
  }) : super.androidDocument(uri: identifier ?? name, name: name);

  final Object? prepareError;
  final Object? releaseError;
  int prepareCount = 0;
  int releaseCount = 0;

  @override
  Future<File> prepare() async {
    prepareCount++;
    if (prepareError != null) throw prepareError!;
    return File('temporary.pdf');
  }

  @override
  Future<void> dispose() async {
    releaseCount++;
    if (releaseError != null) throw releaseError!;
  }
}

void main() {
  setUp(() {
    final previous = Log.isMuted;
    Log.isMuted = true;
    addTearDown(() => Log.isMuted = previous);
  });

  test(
    'prepares and imports one file at a time with page and batch progress',
    () async {
      final files = [_Selection('One.pdf'), _Selection('Two.PDF')];
      final releaseFirst = Completer<void>();
      final firstStarted = Completer<void>();
      final imported = <String>[];
      final progress = <PdfImportBatchProgress>[];
      final batch = PdfImportBatch(
        containsTitle: (_) => false,
        importFile: (file, title, onProgress, cancellation) async {
          if (title == 'One') {
            firstStarted.complete();
            await releaseFirst.future;
          }
          onProgress(0, 2);
          onProgress(1, 2);
          onProgress(2, 2);
          imported.add(title);
        },
      );
      final pending = batch.run(
        files,
        cancellation: DocumentImportCancellation(),
        onProgress: progress.add,
      );
      await firstStarted.future;
      expect(files.first.prepareCount, 1);
      expect(files.last.prepareCount, 0);
      releaseFirst.complete();
      final result = await pending;

      expect(imported, ['One', 'Two']);
      expect(result.count(PdfImportStatus.imported), 2);
      expect(files.map((file) => file.releaseCount), [1, 1]);
      expect(progress.first.fileCount, 2);
      expect(progress.first.pageCount, isNull);
      expect(progress.last.fileIndex, 1);
      expect(progress.last.fileName, 'Two.PDF');
      expect(progress.last.currentPage, 2);
      expect(progress.last.pageCount, 2);
    },
  );

  test(
    'skips duplicates and unsupported types before preparing files',
    () async {
      final files = [
        _Selection('Existing.pdf'),
        _Selection('One.pdf', identifier: 'a/One.pdf'),
        _Selection('One.pdf', identifier: 'a/One.pdf'),
        _Selection('One.pdf', identifier: 'b/One.pdf'),
        _Selection('Other.txt'),
      ];
      final batch = PdfImportBatch(
        containsTitle: (title) => title == 'Existing',
        importFile: (_, title, onProgress, cancellation) async {},
      );
      final result = await batch.run(
        files,
        cancellation: DocumentImportCancellation(),
      );

      expect(result.count(PdfImportStatus.imported), 1);
      expect(result.count(PdfImportStatus.skipped), 4);
      expect(result.items.map((item) => item.skipReason), [
        PdfImportSkipReason.duplicateTitle,
        null,
        PdfImportSkipReason.duplicateFile,
        PdfImportSkipReason.duplicateTitle,
        PdfImportSkipReason.unsupportedFileType,
      ]);
      expect(files.map((file) => file.prepareCount), [0, 1, 0, 0, 0]);
      expect(files.every((file) => file.releaseCount == 1), isTrue);
    },
  );

  test('continues after preparation or conversion errors', () async {
    final readError = Exception('Cannot read document');
    final renderError = const PdfPageRenderException(2);
    final files = [
      _Selection('Unreadable.pdf', prepareError: readError),
      _Selection('Broken.pdf'),
      _Selection('Good.pdf'),
    ];
    final batch = PdfImportBatch(
      containsTitle: (_) => false,
      importFile: (_, title, onProgress, cancellation) async {
        if (title == 'Broken') throw renderError;
      },
    );
    final result = await batch.run(
      files,
      cancellation: DocumentImportCancellation(),
    );

    expect(result.items.map((item) => item.status), [
      PdfImportStatus.failed,
      PdfImportStatus.failed,
      PdfImportStatus.imported,
    ]);
    expect(result.items.first.error, same(readError));
    expect(result.items[1].error, same(renderError));
    expect(files.every((file) => file.releaseCount == 1), isTrue);
  });

  test(
    'a failed title does not prevent importing a different file with that title',
    () async {
      var attempts = 0;
      final batch = PdfImportBatch(
        containsTitle: (_) => false,
        importFile: (_, title, onProgress, cancellation) async {
          if (attempts++ == 0) throw const PdfPageRenderException(1);
        },
      );
      final result = await batch.run([
        _Selection('One.pdf', identifier: 'a/One.pdf'),
        _Selection('One.pdf', identifier: 'b/One.pdf'),
      ], cancellation: DocumentImportCancellation());

      expect(result.count(PdfImportStatus.failed), 1);
      expect(result.count(PdfImportStatus.imported), 1);
    },
  );

  test(
    'cancelling before start releases all selections without opening them',
    () async {
      final files = [_Selection('One.pdf'), _Selection('Two.pdf')];
      final batch = PdfImportBatch(
        containsTitle: (_) => false,
        importFile: (_, title, onProgress, cancellation) async =>
            fail('Unexpected import'),
      );
      final result = await batch.run(
        files,
        cancellation: DocumentImportCancellation()..cancel(),
      );

      expect(result.count(PdfImportStatus.cancelled), 2);
      expect(files.map((file) => file.prepareCount), [0, 0]);
      expect(files.map((file) => file.releaseCount), [1, 1]);
    },
  );

  test(
    'cancellation preserves completed files and never prepares the next file',
    () async {
      final files = [
        _Selection('One.pdf'),
        _Selection('Two.pdf'),
        _Selection('Three.pdf'),
      ];
      final batch = PdfImportBatch(
        containsTitle: (_) => false,
        importFile: (_, title, onProgress, cancellation) async {
          onProgress(1, 2);
          if (title == 'Two') {
            cancellation.cancel();
            cancellation.throwIfCancelled();
          }
        },
      );
      final result = await batch.run(
        files,
        cancellation: DocumentImportCancellation(),
      );

      expect(result.items.map((item) => item.status), [
        PdfImportStatus.imported,
        PdfImportStatus.cancelled,
        PdfImportStatus.cancelled,
      ]);
      expect(result.count(PdfImportStatus.failed), 0);
      expect(files.map((file) => file.prepareCount), [1, 1, 0]);
    },
  );

  test(
    'a late cancellation does not relabel a successfully registered comic',
    () async {
      final batch = PdfImportBatch(
        containsTitle: (_) => false,
        importFile: (_, title, onProgress, cancellation) async =>
            cancellation.cancel(),
      );
      final result = await batch.run([
        _Selection('One.pdf'),
        _Selection('Two.pdf'),
      ], cancellation: DocumentImportCancellation());

      expect(result.count(PdfImportStatus.imported), 1);
      expect(result.count(PdfImportStatus.cancelled), 1);
    },
  );

  test(
    'temporary cleanup failure does not relabel success or stop the queue',
    () async {
      final batch = PdfImportBatch(
        containsTitle: (_) => false,
        importFile: (_, title, onProgress, cancellation) async {},
      );
      final result = await batch.run([
        _Selection('One.pdf', releaseError: Exception('Cleanup failed')),
        _Selection('Two.pdf'),
      ], cancellation: DocumentImportCancellation());

      expect(result.count(PdfImportStatus.imported), 2);
    },
  );
}
