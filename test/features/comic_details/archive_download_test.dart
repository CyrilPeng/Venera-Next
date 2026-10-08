import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_details/archive_download.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/operation_failure.dart';
import 'package:venera_next/network/request_scope.dart';

ArchiveInfo _archive(String id) => ArchiveInfo.fromJson({
  'id': id,
  'title': 'Archive $id',
  'description': 'Description $id',
});

void main() {
  test(
    'archive helpers retain structured source failures and cancellation',
    () async {
      final failure = OperationFailure(
        message: 'Source stopped',
        kind: FailureKind.cancelled,
        cause: const RequestCancelled(),
        stackTrace: StackTrace.current,
      );
      final downloader = ArchiveDownloader(
        (_) async => Res.failure(failure),
        (_, _) async => Res.failure(failure),
      );
      final options = await loadArchiveOptions(downloader, 'comic');
      final link = await loadArchiveDownloadLink(
        downloader,
        'comic',
        'archive',
      );
      expect(options.failure, same(failure));
      expect(link.failure, same(failure));
      expect(options.errorMessage, 'Source stopped');
      expect(link.errorMessage, 'Source stopped');
    },
  );

  test(
    'archive helpers retain thrown causes and their original stacks',
    () async {
      final cause = StateError('source read failed');
      final stack = StackTrace.fromString('original archive source stack');
      final downloader = ArchiveDownloader(
        (_) => Future.error(cause, stack),
        (_, _) => Future.error(cause, stack),
      );
      for (final result in [
        await loadArchiveOptions(downloader, 'comic'),
        await loadArchiveDownloadLink(downloader, 'comic', 'archive'),
      ]) {
        expect(result.failure!.cause, same(cause));
        expect(result.failure!.stackTrace.toString(), stack.toString());
      }
    },
  );

  test(
    'archive helpers classify thrown cancellation without ordinary failure',
    () async {
      const cancellation = RequestCancelled();
      final downloader = ArchiveDownloader(
        (_) async => throw cancellation,
        (_, _) async => throw cancellation,
      );
      for (final result in [
        await loadArchiveOptions(downloader, 'comic'),
        await loadArchiveDownloadLink(downloader, 'comic', 'archive'),
      ]) {
        expect(result.failure!.kind, FailureKind.cancelled);
        expect(result.failure!.cause, same(cancellation));
      }
    },
  );

  test('loads archive options and preserves source errors', () async {
    final successDownloader = ArchiveDownloader(
      (_) async => Res([_archive('1')]),
      (_, _) async => const Res('unused'),
    );
    final errorDownloader = ArchiveDownloader(
      (_) async => const Res.error('source error'),
      (_, _) async => const Res('unused'),
    );

    final success = await loadArchiveOptions(successDownloader, 'comic');
    final error = await loadArchiveOptions(errorDownloader, 'comic');

    expect(success.data.single.id, '1');
    expect(error.errorMessage, 'source error');
  });

  test('converts thrown archive option errors into results', () async {
    final downloader = ArchiveDownloader(
      (_) => throw StateError('network failed'),
      (_, _) async => const Res('unused'),
    );

    final result = await loadArchiveOptions(downloader, 'comic');

    expect(result.error, isTrue);
    expect(result.errorMessage, contains('network failed'));
  });

  test('trims archive links and rejects empty links', () async {
    final validDownloader = ArchiveDownloader(
      (_) async => const Res([]),
      (_, _) async => const Res('  https://example.com/archive.zip  '),
    );
    final emptyDownloader = ArchiveDownloader(
      (_) async => const Res([]),
      (_, _) async => const Res('   '),
    );

    final valid = await loadArchiveDownloadLink(
      validDownloader,
      'comic',
      'archive',
    );
    final empty = await loadArchiveDownloadLink(
      emptyDownloader,
      'comic',
      'archive',
    );

    expect(valid.data, 'https://example.com/archive.zip');
    expect(empty.errorMessage, 'Archive download link is empty');
  });
}
