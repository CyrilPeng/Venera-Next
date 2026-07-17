import 'dart:async' show Future;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera_next/features/comic_storage/comic_storage.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/image_provider/base_image_provider.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'local_comic_image.dart' as image_provider;

class LocalComicImageProvider
    extends BaseImageProvider<image_provider.LocalComicImageProvider> {
  /// Image provider for normal image.
  ///
  /// [url] is the url of the image. Local file path is also supported.
  const LocalComicImageProvider(this.comic);

  final LocalComic comic;

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    File? file = comic.coverFile;
    if (!await file.exists()) {
      file = null;
      var dir = Directory(comic.baseDir);
      if (!await dir.exists()) {
        throw "Error: Comic not found.";
      }
      file = await _inferCover(dir);
    }
    if (file == null) {
      throw "Error: Cover not found.";
    }
    checkStop();
    var data = await file.readAsBytes();
    if (data.isEmpty) {
      throw "Exception: Empty file(${file.path}).";
    }
    return data;
  }

  @override
  Future<LocalComicImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key => "local${comic.id}${comic.comicType.value}";
}

Future<File?> _inferCover(Directory directory) async {
  final entries = await directory.list().toList();
  final rootImages = sortedComicImageEntries(
    entries.whereType<File>(),
    nameOf: (file) => file.name,
  );
  final rootCover = findNamedComicCover(
    rootImages,
    nameOf: (file) => file.name,
  );
  if (rootCover != null) return rootCover;
  if (rootImages.isNotEmpty) return rootImages.first;

  final directories =
      entries
          .whereType<Directory>()
          .where((entry) => !isIgnoredComicStorageEntry(entry.name))
          .toList()
        ..sort((a, b) => compareComicFileNames(a.name, b.name));
  for (final chapter in directories) {
    final images = sortedComicImageEntries(
      (await chapter.list().toList()).whereType<File>(),
      nameOf: (file) => file.name,
    );
    final chapterCover = findNamedComicCover(
      images,
      nameOf: (file) => file.name,
    );
    if (chapterCover != null) return chapterCover;
    if (images.isNotEmpty) return images.first;
  }
  return null;
}
