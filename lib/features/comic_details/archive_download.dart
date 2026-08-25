import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/res.dart';

Future<Res<List<ArchiveInfo>>> loadArchiveOptions(
  ArchiveDownloader downloader,
  String comicId,
) async {
  try {
    final result = await downloader.getArchives(comicId);
    if (result.error) {
      return Res.error(result.errorMessage ?? 'Failed to load archive options');
    }
    return Res(result.dataOrNull ?? const []);
  } catch (error) {
    return Res.error(error.toString());
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
      return Res.error(
        result.errorMessage ?? 'Failed to get archive download link',
      );
    }
    final url = result.dataOrNull?.trim();
    if (url == null || url.isEmpty) {
      return const Res.error('Archive download link is empty');
    }
    return Res(url);
  } catch (error) {
    return Res.error(error.toString());
  }
}
