import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:venera_saf/venera_saf.dart';

import 'app.dart';
import 'file_system.dart';

class ImageSaveDirectoryUnavailable implements Exception {
  const ImageSaveDirectoryUnavailable(this.path, this.cause);
  final String path;
  final Object cause;
  @override
  String toString() => 'Image save directory is unavailable: $path ($cause)';
}

/// Each save owns its new destination and waits for the complete write/close.
/// Android opens the newly returned document URI without looking up an existing
/// filename for truncation. Desktop creation reserves a filename exclusively.
class ImageDirectorySaver {
  const ImageDirectorySaver();

  static bool get supported =>
      !App.isHarmonyOS && (App.isWindows || App.isLinux || App.isAndroid);

  Future<String> save({
    required String directory,
    required File source,
    required String filename,
    void Function()? checkStop,
  }) async {
    checkStop?.call();
    final name = imageSaveFilename(filename);
    if (directory.startsWith('android://')) {
      if (!App.isAndroid) {
        throw ImageSaveDirectoryUnavailable(
          directory,
          const FileSystemException('An Android directory needs Android'),
        );
      }
      try {
        // The native consumer retains the source until its descriptor closes.
        return await AndroidDirectory.fromPathSync(
          directory,
        )!.saveNewFile(source: source, filename: name);
      } on PlatformException catch (error) {
        if (error.code == 'directory_unavailable') {
          throw ImageSaveDirectoryUnavailable(directory, error);
        }
        rethrow;
      }
    }
    if (!p.isAbsolute(directory) || !await Directory(directory).exists()) {
      throw ImageSaveDirectoryUnavailable(
        directory,
        const FileSystemException('The selected directory no longer exists'),
      );
    }
    final stem = name.substring(0, name.length - p.extension(name).length);
    final extension = p.extension(name);
    for (var index = 0; index < 1000; index++) {
      checkStop?.call();
      final candidate = index == 0 ? name : '$stem ($index)$extension';
      final output = File(p.join(directory, candidate));
      try {
        await output.create(exclusive: true);
      } on FileSystemException catch (error) {
        if (await FileSystemEntity.type(output.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          continue;
        }
        if (!await Directory(directory).exists() ||
            [3, 5, 13].contains(error.osError?.errorCode)) {
          throw ImageSaveDirectoryUnavailable(directory, error);
        }
        rethrow;
      }
      try {
        checkStop?.call();
        final expected = await source.length();
        await source.openRead().pipe(output.openWrite());
        if (await output.length() != expected) {
          throw FileSystemException('Incomplete image save', output.path);
        }
        return output.path;
      } catch (error, stack) {
        // Only a destination created by this attempt is eligible for cleanup.
        try {
          await output.delete();
        } catch (_) {
          // Preserve the original write or cancellation error.
        }
        Error.throwWithStackTrace(error, stack);
      }
    }
    throw FileSystemException('Too many files with this image name', directory);
  }
}

/// Retain the chapter/page suffix and actual extension while bounding titles.
String imageSaveFilename(String filename) {
  final clean = filename.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ');
  final extension = p.extension(clean);
  final stem = clean.substring(0, clean.length - extension.length);
  final suffix = RegExp(r'_EP\d+_P\d+$').firstMatch(stem);
  final title = suffix == null ? stem : stem.substring(0, suffix.start);
  // The shared title sanitizer has a UTF-16 limit. Bound complete code points
  // first so that limit cannot split an emoji's surrogate pair.
  final titleBuffer = StringBuffer();
  var units = 0;
  for (final rune in title.runes) {
    final character = String.fromCharCode(
      rune >= 0xd800 && rune <= 0xdfff ? 0xfffd : rune,
    );
    if (units + character.length > maxSanitizedFileNameLength) break;
    titleBuffer.write(character);
    units += character.length;
  }
  var result = sanitizeFileNameWithSuffix(
    titleBuffer.toString(),
    middle: suffix?.group(0) ?? '',
    extension: extension,
    maxUtf8Bytes: maxExportFileNameUtf8Bytes - 8,
  );
  if (RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
    caseSensitive: false,
  ).hasMatch(result)) {
    result = '_$result';
  }
  return result;
}
