import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/file_interaction.dart';

typedef DocumentImportProgress = void Function(int current, int total);

class DocumentImportSession {
  DocumentImportSession._({required this.title, required this.directory});

  final String title;
  final Directory directory;

  static DocumentImportSession start(String title) {
    final normalizedTitle = title.trim();
    if (normalizedTitle.isEmpty) {
      throw const FormatException('Document title is empty');
    }
    if (LocalManager().findByName(normalizedTitle) != null) {
      throw Exception('Comic with name $normalizedTitle already exists');
    }

    final localPath = LocalManager().path;
    final directoryName = findValidDirectoryName(
      localPath,
      sanitizeFileName(normalizedTitle, maxLength: maxSanitizedFileNameLength),
    );
    final directory = Directory(FilePath.join(localPath, directoryName));
    directory.createSync(recursive: true);
    return DocumentImportSession._(
      title: normalizedTitle,
      directory: directory,
    );
  }

  String pagePath({
    required int pageIndex,
    required String extension,
    String? chapterId,
  }) {
    final normalizedExtension = _normalizeExtension(extension);
    final fileName =
        '${pageIndex.toString().padLeft(4, '0')}.$normalizedExtension';
    if (chapterId == null) {
      return FilePath.join(directory.path, fileName);
    }
    final chapterDirectory = Directory(FilePath.join(directory.path, chapterId))
      ..createSync(recursive: true);
    return FilePath.join(chapterDirectory.path, fileName);
  }

  Future<void> copyPage(
    File source, {
    required int pageIndex,
    required String extension,
    String? chapterId,
  }) {
    return source.copyMem(
      pagePath(
        pageIndex: pageIndex,
        extension: extension,
        chapterId: chapterId,
      ),
    );
  }

  Future<String> copyCover(File source, {required String extension}) async {
    final coverName = 'cover.${_normalizeExtension(extension)}';
    await source.copyMem(FilePath.join(directory.path, coverName));
    return coverName;
  }

  LocalComic finish({
    required String author,
    required List<String> tags,
    required String cover,
    Map<String, String>? chapters,
  }) {
    final normalizedChapters = chapters == null || chapters.isEmpty
        ? null
        : Map<String, String>.from(chapters);
    return LocalComic(
      id: LocalManager().findValidId(ComicType.local),
      title: title,
      subtitle: author,
      tags: tags,
      directory: directory.name,
      chapters: normalizedChapters == null
          ? null
          : ComicChapters(normalizedChapters),
      cover: cover,
      comicType: ComicType.local,
      downloadedChapters: normalizedChapters?.keys.toList() ?? const [],
      createdAt: DateTime.now(),
    );
  }

  Future<void> abort() => directory.deleteIgnoreError(recursive: true);

  static String _normalizeExtension(String extension) {
    final normalized = extension.startsWith('.')
        ? extension.substring(1)
        : extension;
    if (normalized.isEmpty) {
      throw const FormatException('Image extension is empty');
    }
    return normalized.toLowerCase();
  }
}
