import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

export 'dart:io';
export 'dart:typed_data';

class FilePath {
  const FilePath._();

  static String join(
    String path1,
    String path2, [
    String? path3,
    String? path4,
    String? path5,
  ]) {
    return p.join(path1, path2, path3, path4, path5);
  }
}

extension FileSystemEntityExt on FileSystemEntity {
  /// Get the base name of the file or directory.
  String get name {
    return p.basename(path);
  }

  /// Delete the file or directory and ignore errors.
  Future<void> deleteIgnoreError({bool recursive = false}) async {
    try {
      await delete(recursive: recursive);
    } catch (e) {
      // ignore
    }
  }

  /// Delete the file or directory if it exists.
  Future<void> deleteIfExists({bool recursive = false}) async {
    if (existsSync()) {
      await delete(recursive: recursive);
    }
  }

  /// Delete the file or directory if it exists.
  void deleteIfExistsSync({bool recursive = false}) {
    if (existsSync()) {
      deleteSync(recursive: recursive);
    }
  }
}

extension FileExtension on File {
  /// Get the file extension, not including the dot.
  String get extension => path.split('.').last;

  /// Copy the file to the specified path using memory.
  ///
  /// This method prevents errors caused by files from different file systems.
  Future<void> copyMem(String newPath) async {
    var newFile = File(newPath);
    // Stream is not usable since [AndroidFile] does not support [openRead].
    await newFile.writeAsBytes(await readAsBytes());
  }

  /// Get the base name of the file without the extension.
  String get basenameWithoutExt {
    return p.basenameWithoutExtension(path);
  }
}

extension DirectoryExtension on Directory {
  /// Calculate the size of the directory.
  Future<int> get size async {
    if (!existsSync()) return 0;
    int total = 0;
    for (var f in listSync(recursive: true)) {
      if (FileSystemEntity.typeSync(f.path) == FileSystemEntityType.file) {
        total += await File(f.path).length();
      }
    }
    return total;
  }

  /// Change the base name of the directory.
  Directory renameX(String newName) {
    newName = sanitizeFileName(newName);
    return renameSync(_replaceLast(path, name, newName));
  }

  File joinFile(String name) {
    return File(FilePath.join(path, name));
  }

  /// Delete the contents of the directory.
  void deleteContentsSync({recursive = true}) {
    if (!existsSync()) return;
    for (var f in listSync()) {
      f.deleteIfExistsSync(recursive: recursive);
    }
  }

  /// Delete the contents of the directory.
  Future<void> deleteContents({recursive = true}) async {
    if (!existsSync()) return;
    for (var f in listSync()) {
      await f.deleteIfExists(recursive: recursive);
    }
  }

  /// Create the directory. If the directory already exists, delete it first.
  void forceCreateSync() {
    if (existsSync()) {
      deleteSync(recursive: true);
    }
    createSync(recursive: true);
  }
}

String _replaceLast(String value, String from, String to) {
  if (value.isEmpty || from.isEmpty) {
    return value;
  }

  final lastIndex = value.lastIndexOf(from);
  if (lastIndex == -1) {
    return value;
  }

  final before = value.substring(0, lastIndex);
  final after = value.substring(lastIndex + from.length);
  return '$before$to$after';
}

/// Soft upper bound for the sanitized title portion of a filename, in characters.
const maxSanitizedFileNameLength = 80;

/// Hard upper bound for an exported filename, in UTF-8 bytes.
///
/// APFS (iOS/macOS) caps a single path component at 255 UTF-8 bytes. 230 leaves
/// a small margin for platform / sync layers that prepend metadata.
const maxExportFileNameUtf8Bytes = 230;

const _defaultFallback = 'file';

/// Path-illegal characters shared by [sanitizeFileName] and
/// [sanitizeFileNameWithSuffix].
final _invalidFileNameChars = RegExp(r'[<>:"/\\|?*]');

/// Replace invalid characters with a space (matches [sanitizeFileName]).
String _replaceInvalidChars(String value) =>
    value.replaceAll(_invalidFileNameChars, ' ');

/// Sanitize the file name. Remove invalid characters and trim the file name.
String sanitizeFileName(String fileName, {String? dir, int? maxLength}) {
  while (fileName.endsWith('.')) {
    fileName = fileName.substring(0, fileName.length - 1);
  }
  var length = maxLength ?? 255;
  if (dir != null) {
    if (!dir.endsWith('/') && !dir.endsWith('\\')) {
      dir = "$dir/";
    }
    length -= dir.length;
  }
  var trimmedFileName = _replaceInvalidChars(fileName).trim();
  if (trimmedFileName.isEmpty) {
    throw Exception('Invalid File Name: Empty length.');
  }
  if (length <= 0) {
    throw Exception('Invalid File Name: Max length is less than 0.');
  }
  if (trimmedFileName.length > length) {
    trimmedFileName = trimmedFileName.substring(0, length);
  }
  return trimmedFileName;
}

/// Truncate `value` to fit within `maxBytes` UTF-8 bytes, aligned on Unicode
/// code points. Byte-faithful: trailing whitespace is preserved.
///
/// Note: iteration is by code point (rune), not by grapheme cluster, so NFD
/// composed forms (e.g. Japanese `し` + `゙` = `じ`) may split at the boundary,
/// leaving an orphan combining mark. Production input is typically NFC so this
/// is rare in practice; switch to `package:characters` if strict grapheme
/// alignment is needed.
String _truncateUtf8(String value, int maxBytes) {
  if (maxBytes <= 0) return '';
  var usedBytes = 0;
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    final char = String.fromCharCode(rune);
    final charBytes = utf8.encode(char).length;
    if (usedBytes + charBytes > maxBytes) break;
    buffer.write(char);
    usedBytes += charBytes;
  }
  return buffer.toString();
}

/// Build an export filename of the form `{title}{middle}{extension}`.
///
/// - Invalid path characters in [middle] and [extension] are replaced with
///   spaces. The chapter title contained in [middle] is user-controlled data
///   and may contain `/`, `:`, `*`, etc.
/// - [extension] is preserved whenever possible: if [middle] + [extension] fits
///   within [maxUtf8Bytes] the extension is appended verbatim (modulo invalid
///   chars). If they together overflow [maxUtf8Bytes] the title is dropped and
///   only [middle] is byte-truncated; [extension] is still appended in full. If
///   [extension] alone overflows [maxUtf8Bytes] (pathological) it is truncated.
/// - The title is capped at [maxSanitizedFileNameLength] characters (soft) and
///   further by the remaining UTF-8 byte budget (hard).
/// - When the title sanitizes to empty, [fallback] is used; if [fallback] also
///   sanitizes to empty the literal `'file'` is used. The function never throws.
String sanitizeFileNameWithSuffix(
  String fileName, {
  String middle = '',
  required String extension,
  int maxUtf8Bytes = maxExportFileNameUtf8Bytes,
  String fallback = _defaultFallback,
}) {
  final cleanMiddle = _replaceInvalidChars(middle);
  final cleanExtension = _replaceInvalidChars(extension);
  final extensionBytes = utf8.encode(cleanExtension).length;

  if (extensionBytes >= maxUtf8Bytes) {
    return _truncateUtf8(cleanExtension, maxUtf8Bytes);
  }

  final middleBytes = utf8.encode(cleanMiddle).length;
  if (middleBytes + extensionBytes >= maxUtf8Bytes) {
    final middleBudget = maxUtf8Bytes - extensionBytes;
    return '${_truncateUtf8(cleanMiddle, middleBudget)}$cleanExtension';
  }

  final titleBudget = maxUtf8Bytes - middleBytes - extensionBytes;

  String trySanitize(String input) {
    try {
      return sanitizeFileName(input, maxLength: maxSanitizedFileNameLength);
    } catch (_) {
      return '';
    }
  }

  var title = _truncateUtf8(trySanitize(fileName), titleBudget).trimRight();
  if (title.isEmpty) {
    title = _truncateUtf8(trySanitize(fallback), titleBudget).trimRight();
  }
  if (title.isEmpty) {
    title = _truncateUtf8(_defaultFallback, titleBudget);
  }
  return '$title$cleanMiddle$cleanExtension';
}

/// Copy the **contents** of the source directory to the destination directory.
Future<void> copyDirectory(Directory source, Directory destination) async {
  if (!destination.existsSync()) {
    destination.createSync();
  }
  List<FileSystemEntity> contents = source.listSync();
  for (FileSystemEntity content in contents) {
    String newPath = FilePath.join(destination.path, content.name);

    if (content is File) {
      var resultFile = File(newPath);
      resultFile.createSync();
      var data = content.readAsBytesSync();
      resultFile.writeAsBytesSync(data);
    } else if (content is Directory) {
      Directory newDirectory = Directory(newPath);
      newDirectory.createSync();
      copyDirectory(content.absolute, newDirectory.absolute);
    }
  }
}

String findValidDirectoryName(String path, String directory) {
  var name = sanitizeFileName(directory);
  var dir = Directory("$path/$name");
  var i = 1;
  while (dir.existsSync() && dir.listSync().isNotEmpty) {
    name = sanitizeFileName("$directory($i)");
    dir = Directory("$path/$name");
    i++;
  }
  return name;
}

String bytesToReadableString(int bytes) {
  if (bytes < 1024) {
    return "$bytes B";
  } else if (bytes < 1024 * 1024) {
    return "${(bytes / 1024).toStringAsFixed(2)} KB";
  } else if (bytes < 1024 * 1024 * 1024) {
    return "${(bytes / 1024 / 1024).toStringAsFixed(2)} MB";
  } else {
    return "${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB";
  }
}
