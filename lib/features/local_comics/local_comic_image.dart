import 'package:venera_next/foundation/operation_failure.dart';
import 'dart:async' show Future;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera_next/features/comic_storage/comic_storage.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/image_provider/base_image_provider.dart';
import 'package:venera_next/foundation/file_system.dart';

class LocalComicImageProvider
    extends BaseImageProvider<LocalComicImageProvider> {
  /// Image provider for normal image.
  ///
  /// [url] is the url of the image. Local file path is also supported.
  const LocalComicImageProvider(this.comic);

  final LocalComic comic;

  @protected
  File get coverFile => comic.coverFile;

  @protected
  Directory get comicDirectory => Directory(comic.baseDir);

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    checkStop();
    File? file = coverFile;
    final exists = await file.exists();
    checkStop();
    if (!exists) {
      file = null;
      var dir = comicDirectory;
      final directoryExists = await dir.exists();
      checkStop();
      if (!directoryExists) {
        throw OperationFailure.message("Error: Comic not found.");
      }
      file = await _inferCover(dir, checkStop);
    }
    if (file == null) {
      throw OperationFailure.message("Error: Cover not found.");
    }
    checkStop();
    var data = await file.readAsBytes();
    if (data.isEmpty) {
      throw OperationFailure.message("Exception: Empty file(${file.path}).");
    }
    checkStop();
    return data;
  }

  @override
  Future<LocalComicImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key => "local${comic.id}${comic.comicType.value}";
}

Future<File?> _inferCover(
  Directory directory,
  void Function() checkStop,
) async {
  checkStop();
  final entries = await directory.list().toList();
  checkStop();
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
    checkStop();
    final entries = await chapter.list().toList();
    checkStop();
    final images = sortedComicImageEntries(
      entries.whereType<File>(),
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
