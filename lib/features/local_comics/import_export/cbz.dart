import 'dart:convert';
import 'package:flutter_7zip/flutter_7zip.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/extensions.dart';
import 'package:venera_next/foundation/file_type.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'package:zip_flutter/zip_flutter.dart';

class ComicMetaData {
  final String title;

  final String author;

  final List<String> tags;

  final List<ComicChapter>? chapters;

  Map<String, dynamic> toJson() => {
    'title': title,
    'author': author,
    'tags': tags,
    'chapters': chapters?.map((e) => e.toJson()).toList(),
  };

  ComicMetaData.fromJson(Map<String, dynamic> json)
    : title = json['title'],
      author = json['author'],
      tags = List<String>.from(json['tags']),
      chapters = json['chapters'] == null
          ? null
          : List<ComicChapter>.from(
              json['chapters'].map((e) => ComicChapter.fromJson(e)),
            );

  ComicMetaData({
    required this.title,
    required this.author,
    required this.tags,
    this.chapters,
  });
}

class ComicChapter {
  final String title;

  final int start;

  final int end;

  Map<String, dynamic> toJson() => {'title': title, 'start': start, 'end': end};

  ComicChapter.fromJson(Map<String, dynamic> json)
    : title = json['title'],
      start = json['start'],
      end = json['end'];

  ComicChapter({required this.title, required this.start, required this.end});
}

/// Comic Book Archive. Currently supports CBZ, ZIP and 7Z formats.
abstract class CBZ {
  static Future<FileType> checkType(File file) async {
    var header = <int>[];
    await for (var bytes in file.openRead()) {
      header.addAll(bytes);
      if (header.length >= 32) break;
    }
    return detectFileType(header);
  }

  static Future<void> extractArchive(File file, Directory out) async {
    var fileType = await checkType(file);
    if (fileType.mime == 'application/zip') {
      await ZipFile.openAndExtractAsync(file.path, out.path, 4);
    } else if (fileType.mime == "application/x-7z-compressed") {
      await SZArchive.extractIsolates(file.path, out.path, 4);
    } else {
      throw Exception('Unsupported archive type');
    }
  }

  static Future<LocalComic> import(File file) async {
    var cache = Directory(FilePath.join(App.cachePath, 'cbz_import'));
    if (cache.existsSync()) cache.deleteSync(recursive: true);
    cache.createSync();
    await extractArchive(file, cache);
    var f = cache.listSync();
    if (f.length == 1 && f.first is Directory) {
      cache = f.first as Directory;
    }
    var metaDataFile = File(FilePath.join(cache.path, 'metadata.json'));
    ComicMetaData? metaData;
    if (metaDataFile.existsSync()) {
      try {
        metaData = ComicMetaData.fromJson(
          jsonDecode(metaDataFile.readAsStringSync()),
        );
      } catch (e) {
        Log.warning("CBZ", "Failed to parse metadata: $e");
      }
    }
    metaData ??= ComicMetaData(
      title: file.name.substring(0, file.name.lastIndexOf('.')),
      author: "",
      tags: [],
    );
    var old = LocalManager().findByName(metaData.title);
    if (old != null) {
      throw Exception('Comic with name ${metaData.title} already exists');
    }
    var files = cache.listSync().whereType<File>().toList();
    files.removeWhere((e) {
      var ext = e.path.split('.').last;
      return !['jpg', 'jpeg', 'png', 'webp', 'gif', 'jpe'].contains(ext);
    });
    if (files.isEmpty) {
      cache.deleteSync(recursive: true);
      throw Exception('No images found in the archive');
    }
    files.sort((a, b) {
      var aName = a.basenameWithoutExt;
      var bName = b.basenameWithoutExt;
      var aIndex = int.tryParse(aName);
      var bIndex = int.tryParse(bName);
      if (aIndex != null && bIndex != null) {
        return aIndex.compareTo(bIndex);
      } else {
        return a.path.compareTo(b.path);
      }
    });
    var coverFile = files.firstWhereOrNull(
      (element) =>
          element.path.endsWith('cover.${element.path.split('.').last}'),
    );
    if (coverFile != null) {
      files.remove(coverFile);
    } else {
      coverFile = files.first;
    }
    Map<String, String>? cpMap;
    var dest = Directory(
      FilePath.join(
        LocalManager().path,
        sanitizeFileName(metaData.title, maxLength: maxSanitizedFileNameLength),
      ),
    );
    dest.createSync();
    coverFile.copyMem(FilePath.join(dest.path, 'cover.${coverFile.extension}'));
    if (metaData.chapters == null) {
      for (var i = 0; i < files.length; i++) {
        var src = files[i];
        var dst = File(
          FilePath.join(dest.path, '${i + 1}.${src.path.split('.').last}'),
        );
        await src.copyMem(dst.path);
      }
    } else {
      dest.createSync();
      var chapters = <String, List<File>>{};
      for (var chapter in metaData.chapters!) {
        chapters[chapter.title] = files.sublist(chapter.start - 1, chapter.end);
      }
      int i = 0;
      cpMap = <String, String>{};
      for (var chapter in chapters.entries) {
        cpMap[i.toString()] = chapter.key;
        var chapterDir = Directory(FilePath.join(dest.path, i.toString()));
        chapterDir.createSync();
        for (var j = 0; j < chapter.value.length; j++) {
          var src = chapter.value[j];
          var dst = File(
            FilePath.join(
              chapterDir.path,
              '${j + 1}.${src.path.split('.').last}',
            ),
          );
          await src.copyMem(dst.path);
        }
        i++;
      }
    }
    var comic = LocalComic(
      id: LocalManager().findValidId(ComicType.local),
      title: metaData.title,
      subtitle: metaData.author,
      tags: metaData.tags,
      comicType: ComicType.local,
      directory: dest.name,
      chapters: ComicChapters.fromJsonOrNull(cpMap),
      downloadedChapters: cpMap?.keys.toList() ?? [],
      cover: 'cover.${coverFile.extension}',
      createdAt: DateTime.now(),
    );
    await cache.delete(recursive: true);
    return comic;
  }

  static Future<File> export(LocalComic comic, String outFilePath) async {
    var cache = Directory(FilePath.join(App.cachePath, 'cbz_export'));
    if (cache.existsSync()) cache.deleteSync(recursive: true);
    cache.createSync();
    List<ComicChapter>? chapters;
    var pageCount = 0;
    if (comic.chapters == null) {
      var images = await LocalManager().getImages(comic.id, comic.comicType, 1);
      pageCount = images.length;
      int i = 1;
      for (var image in images) {
        var src = File(_localFilePathFromImageUri(image));
        var dstName = compatiblePageFileName(i, image.split('.').last);
        var dst = File(FilePath.join(cache.path, dstName));
        await src.copyMem(dst.path);
        i++;
      }
    } else {
      var allImages = <String>[];
      final chapterPageCounts = <MapEntry<String, int>>[];
      for (var c in comic.downloadedChapters) {
        var chapterName = comic.chapters![c];
        var images = await LocalManager().getImages(
          comic.id,
          comic.comicType,
          c,
        );
        allImages.addAll(images);
        chapterPageCounts.add(MapEntry(chapterName!, images.length));
      }
      chapters = _buildChapterRanges(chapterPageCounts);
      pageCount = allImages.length;
      int i = 1;
      for (var image in allImages) {
        var src = File(_localFilePathFromImageUri(image));
        var dstName = compatiblePageFileName(i, image.split('.').last);
        var dst = File(FilePath.join(cache.path, dstName));
        await src.copyMem(dst.path);
        i++;
      }
    }
    var cover = comic.coverFile;
    await cover.copyMem(
      FilePath.join(cache.path, 'cover.${cover.path.split('.').last}'),
    );
    final metaData = ComicMetaData(
      title: comic.title,
      author: comic.subtitle,
      tags: comic.tags,
      chapters: chapters,
    );
    await File(
      FilePath.join(cache.path, 'metadata.json'),
    ).writeAsString(jsonEncode(metaData));
    await File(
      FilePath.join(cache.path, 'ComicInfo.xml'),
    ).writeAsString(_buildComicInfoXml(metaData, pageCount: pageCount));
    var cbz = File(outFilePath);
    if (cbz.existsSync()) cbz.deleteSync();
    await _compress(cache.path, cbz.path);
    cache.deleteSync(recursive: true);
    return cbz;
  }

  static String compatiblePageFileName(int pageIndex, String extension) {
    final normalizedExtension = extension.startsWith('.')
        ? extension.substring(1)
        : extension;
    return '${pageIndex.toString().padLeft(4, '0')}.$normalizedExtension';
  }

  static String localFilePathFromImageUriForTesting(String imageUri) {
    return _localFilePathFromImageUri(imageUri);
  }

  static String _localFilePathFromImageUri(String imageUri) {
    return imageUri.replaceFirst('file://', '');
  }

  static List<ComicChapter> buildChapterRangesForTesting(
    Map<String, int> chapterPageCounts,
  ) {
    return _buildChapterRanges(chapterPageCounts.entries);
  }

  static List<ComicChapter> _buildChapterRanges(
    Iterable<MapEntry<String, int>> chapterPageCounts,
  ) {
    final chapters = <ComicChapter>[];
    var nextPage = 1;
    for (final chapter in chapterPageCounts) {
      final start = nextPage;
      final end = start + chapter.value - 1;
      chapters.add(ComicChapter(title: chapter.key, start: start, end: end));
      nextPage = end + 1;
    }
    return chapters;
  }

  static String buildComicInfoXmlForTesting(
    ComicMetaData data, {
    required int pageCount,
  }) {
    return _buildComicInfoXml(data, pageCount: pageCount);
  }

  static String _buildComicInfoXml(
    ComicMetaData data, {
    required int pageCount,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('<?xml version="1.0" encoding="utf-8"?>');
    buffer.writeln(
      '<ComicInfo xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">',
    );

    buffer.writeln('  <Title>${_escapeXml(data.title)}</Title>');
    buffer.writeln('  <Series>${_escapeXml(data.title)}</Series>');

    final comicInfoTags = _buildComicInfoTags(data);

    if (comicInfoTags.writer.isNotEmpty) {
      buffer.writeln('  <Writer>${_escapeXml(comicInfoTags.writer)}</Writer>');
    }

    if (comicInfoTags.genres.isNotEmpty) {
      buffer.writeln(
        '  <Genre>${_escapeXml(comicInfoTags.genres.join(', '))}</Genre>',
      );
    }

    if (comicInfoTags.tags.isNotEmpty) {
      buffer.writeln(
        '  <Tags>${_escapeXml(comicInfoTags.tags.join(', '))}</Tags>',
      );
    }

    buffer.writeln('  <PageCount>$pageCount</PageCount>');

    if (data.chapters != null && data.chapters!.isNotEmpty) {
      final chaptersInfo = data.chapters!
          .map(
            (chapter) =>
                '${_escapeXml(chapter.title)}: ${chapter.start}-${chapter.end}',
          )
          .join('; ');
      buffer.writeln('  <Notes>Chapters: $chaptersInfo</Notes>');
    }

    buffer.writeln('  <Manga>Unknown</Manga>');
    buffer.writeln('  <BlackAndWhite>Unknown</BlackAndWhite>');

    if (pageCount > 0) {
      buffer.writeln('  <Pages>');
      for (var i = 0; i < pageCount; i++) {
        buffer.writeln('    <Page Image="$i" Type="Story" />');
      }
      buffer.writeln('  </Pages>');
    }

    final now = DateTime.now();
    buffer.writeln('  <Year>${now.year}</Year>');

    buffer.writeln('</ComicInfo>');
    return buffer.toString();
  }

  static String _escapeXml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  static _ComicInfoTags _buildComicInfoTags(ComicMetaData data) {
    final writers = <String>[];
    if (data.author.isNotEmpty) {
      writers.add(data.author);
    }

    final genres = <String>[];
    final tags = <String>[];

    for (final tag in data.tags) {
      final normalizedTag = tag.trim();
      if (normalizedTag.isEmpty) continue;

      final separator = normalizedTag.indexOf(':');
      if (separator <= 0) {
        tags.add(normalizedTag);
        continue;
      }

      final key = normalizedTag.substring(0, separator).trim().toLowerCase();
      final value = normalizedTag.substring(separator + 1).trim();
      if (value.isEmpty) continue;

      switch (key) {
        case 'author':
        case 'authors':
        case 'artist':
        case 'artists':
          writers.addAll(_splitComicInfoValues(value));
        case 'category':
        case 'categories':
        case 'genre':
        case 'genres':
          genres.addAll(_splitComicInfoValues(value));
        case 'tag':
        case 'tags':
          tags.addAll(_splitComicInfoValues(value));
        default:
          tags.add(normalizedTag);
      }
    }

    return _ComicInfoTags(
      writer: _uniqueValues(writers).join(', '),
      genres: _uniqueValues(genres),
      tags: _uniqueValues(tags),
    );
  }

  static List<String> _splitComicInfoValues(String value) {
    return value
        .split(RegExp(r'[,，]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  static List<String> _uniqueValues(List<String> values) {
    return values.toSet().toList();
  }

  static _compress(String src, String dst) async {
    await ZipFile.compressFolderAsync(src, dst, 4);
  }
}

class _ComicInfoTags {
  final String writer;

  final List<String> genres;

  final List<String> tags;

  _ComicInfoTags({
    required this.writer,
    required this.genres,
    required this.tags,
  });
}
