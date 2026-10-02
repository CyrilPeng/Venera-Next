import 'dart:convert';
import 'package:venera_next/features/comic_storage/comic_storage.dart';
import 'package:venera_next/foundation/extensions.dart';
import 'package:venera_next/foundation/log.dart';
import 'webdav_library_entries.dart';
import 'webdav_library_session.dart';
import 'webdav_library_snapshot.dart';

class WebDavLibrarySnapshotBuilder {
  const WebDavLibrarySnapshotBuilder(this.session);

  final WebDavLibrarySession session;

  Future<WebDavComicSnapshot> build(
    String id, {
    List<WebDavLibraryEntry>? rootEntries,
  }) async {
    session.check();
    final config = session.config;
    final comicPath = config.childDirectoryPath(id);
    final entries = List<WebDavLibraryEntry>.from(
      rootEntries ?? await session.readDir(comicPath),
    );
    final rootImages = webDavImageEntries(
      entries,
    ).where((entry) => !isNamedComicCover(entry.name)).toList();
    final directories = webDavSortedDirectories(entries);
    final metadata = await _readMetadata(
      comicPath,
      entries,
      pageCount: directories.isEmpty ? rootImages.length : null,
    );

    final metadataChapters = <String, ComicChapter>{};
    final chapterMap = <String, String>{};
    if (directories.isNotEmpty) {
      for (final directory in directories) {
        chapterMap[directory.name] = directory.name;
      }
      if (rootImages.isNotEmpty) {
        chapterMap[webDavRootChapterId] = webDavRootChapterTitle;
      }
    } else if (metadata?.chapters?.isNotEmpty == true) {
      for (var index = 0; index < metadata!.chapters!.length; index++) {
        final chapter = metadata.chapters![index];
        final chapterId = '$webDavMetadataChapterPrefix$index';
        metadataChapters[chapterId] = chapter;
        chapterMap[chapterId] = chapter.title;
      }
    } else if (rootImages.isNotEmpty) {
      chapterMap[webDavRootChapterId] = webDavRootChapterTitle;
    }
    if (chapterMap.isEmpty) {
      throw const FormatException(
        'No images found in the WebDAV comic directory',
      );
    }

    final namedCover = webDavFindNamedCover(entries);
    String? coverPath = namedCover == null
        ? null
        : config.childFilePath(comicPath, namedCover.name);
    if (rootImages.isNotEmpty) {
      coverPath ??= config.childFilePath(comicPath, rootImages.first.name);
    }
    if (coverPath == null) {
      for (final directory in directories) {
        final chapterPath = config.childDirectoryPathFrom(
          comicPath,
          directory.name,
        );
        try {
          final chapterEntries = List<WebDavLibraryEntry>.from(
            await session.readDir(chapterPath),
          );
          final chapterCover = webDavFindNamedCover(chapterEntries);
          final chapterPages = webDavImageEntries(
            chapterEntries,
          ).where((entry) => !isNamedComicCover(entry.name)).toList();
          final coverEntry = chapterCover ?? chapterPages.firstOrNull;
          if (coverEntry != null) {
            coverPath = config.childFilePath(chapterPath, coverEntry.name);
            break;
          }
        } catch (e) {
          if (e is WebDavLibraryCancelled) rethrow;
          Log.warning(
            'WebDAV Library',
            'Failed to inspect chapter cover at $chapterPath: $e',
          );
        }
      }
    }

    session.check();
    final metadataTitle = metadata?.title.trim() ?? '';
    return WebDavComicSnapshot(
      title: metadataTitle.isEmpty ? _directoryName(id) : metadataTitle,
      author: metadata?.author ?? '',
      tags: metadata?.tags ?? const [],
      cover: coverPath ?? '',
      chapters: chapterMap,
      metadataChapters: metadataChapters,
      rootImages: rootImages,
    );
  }

  Future<ComicMetaData?> _readMetadata(
    String comicPath,
    List<WebDavLibraryEntry> entries, {
    int? pageCount,
  }) async {
    session.check();
    final config = session.config;
    final metadataEntry = entries.firstWhereOrNull(
      (entry) =>
          !entry.isDirectory &&
          entry.name.toLowerCase() == webDavMetadataFileName,
    );
    if (metadataEntry == null) return null;

    final metadataPath = config.childFilePath(comicPath, metadataEntry.name);
    try {
      final decoded = jsonDecode(await session.readText(metadataPath));
      if (decoded is! Map) {
        throw const FormatException('metadata.json must contain an object');
      }
      final metadata = ComicMetaData.fromJson(
        Map<String, dynamic>.from(decoded),
      );
      metadata.validateChapterRanges(pageCount: pageCount);
      return metadata;
    } catch (e) {
      if (e is WebDavLibraryCancelled) rethrow;
      Log.warning(
        'WebDAV Library',
        'Ignoring invalid metadata at $metadataPath: $e',
      );
      return null;
    }
  }

  static String _directoryName(String id) {
    final separator = id.lastIndexOf('/');
    return separator < 0 ? id : id.substring(separator + 1);
  }
}
