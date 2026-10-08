import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/operation_failure.dart';
import 'package:venera_next/network/request_scope.dart';

Future<Res<List<ArchiveInfo>>> loadArchiveOptions(
  ArchiveDownloader downloader,
  String comicId,
) async {
  try {
    final result = await downloader.getArchives(comicId);
    if (result.error) {
      return Res.fromErrorRes(result);
    }
    return Res(result.dataOrNull ?? const []);
  } catch (error, stack) {
    return _archiveFailure(error, stack);
  }
}

Future<Res<String>> loadArchiveDownloadLink(
  ArchiveDownloader downloader,
  String comicId,
  String archiveId,
) async {
  try {
    final result = await downloader.getDownloadUrl(comicId, archiveId);
    if (result.error) {
      return Res.fromErrorRes(result);
    }
    final url = result.dataOrNull?.trim();
    if (url == null || url.isEmpty) {
      return const Res.error('Archive download link is empty');
    }
    return Res(url);
  } catch (error, stack) {
    return _archiveFailure(error, stack);
  }
}

Res<T> _archiveFailure<T>(Object error, StackTrace stack) {
  if (error is RequestCancelled) {
    return Res.failure(
      OperationFailure(
        message: error.toString(),
        kind: FailureKind.cancelled,
        cause: error,
        stackTrace: stack,
      ),
    );
  }
  return Res.fromException(error, stack);
}
