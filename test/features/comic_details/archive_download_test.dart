import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_details/archive_download.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/res.dart';

ArchiveInfo _archive(String id) => ArchiveInfo.fromJson({
  'id': id,
  'title': 'Archive $id',
  'description': 'Description $id',
});

void main() {
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
