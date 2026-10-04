import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// A failed share/write and a failed cleanup retain their original diagnostics.
class ShareFileCleanupFailure implements Exception {
  const ShareFileCleanupFailure({
    required this.operationError,
    required this.operationStackTrace,
    required this.cleanupError,
    required this.cleanupStackTrace,
  });

  final Object operationError;
  final StackTrace operationStackTrace;
  final Object cleanupError;
  final StackTrace cleanupStackTrace;

  @override
  String toString() =>
      'Share failed: $operationError; source cleanup failed: $cleanupError';
}

/// Writes one independently owned share source before invoking [share].
///
/// Set [retainAfterDispatch] when the platform's result acknowledges dispatch,
/// rather than the end of source borrowing. Such sources remain available even
/// if dispatch throws: an error cannot prove that nobody received the path.
/// This helper does not expire retained sources or delete the shared namespace.
/// Platforms that finish borrowing before their Future completes can opt out.
Future<T> withShareFileSource<T>({
  required Uint8List data,
  required String filename,
  required Directory cacheDirectory,
  required Future<T> Function(File source) share,
  required bool retainAfterDispatch,
  void Function()? checkStop,
}) async {
  Directory? owned;
  var dispatched = false;
  Object? operationError;
  StackTrace? operationStack;
  try {
    checkStop?.call();
    await cacheDirectory.create(recursive: true);
    checkStop?.call();
    owned = await cacheDirectory.createTemp('share-');
    checkStop?.call();
    final source = File(p.join(owned.path, _sourceName(filename, owned)));
    await source.writeAsBytes(data, flush: true);
    if (await source.length() != data.length) {
      throw FileSystemException('Incomplete share source write', source.path);
    }
    checkStop?.call();
    // Mark before entering injected/platform code, including a synchronous
    // throw. Only that code can know whether it has already passed the path on.
    dispatched = true;
    return await share(source);
  } catch (error, stack) {
    operationError = error;
    operationStack = stack;
    rethrow;
  } finally {
    if (owned != null && (!dispatched || !retainAfterDispatch)) {
      try {
        await owned.delete(recursive: true);
      } catch (cleanupError, cleanupStack) {
        if (operationError != null) {
          Error.throwWithStackTrace(
            ShareFileCleanupFailure(
              operationError: operationError,
              operationStackTrace: operationStack!,
              cleanupError: cleanupError,
              cleanupStackTrace: cleanupStack,
            ),
            operationStack,
          );
        }
        Error.throwWithStackTrace(cleanupError, cleanupStack);
      }
    }
  }
}

final _invalidNameCharacters = RegExp(r'[<>:"/\\|?*\x00-\x1f]');
final _trailingDotsAndSpaces = RegExp(r'[. ]+$');
final _deviceName = RegExp(
  r'^(CON|PRN|AUX|NUL|CLOCK\$|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³])$',
  caseSensitive: false,
);

String _sourceName(String filename, Directory directory) {
  var name = p.posix.basename(filename.replaceAll('\\', '/'));
  name = name
      .replaceAll(_invalidNameCharacters, '_')
      .replaceAll(_trailingDotsAndSpaces, '');
  if (name.isEmpty) name = 'shared-file';

  // A component must fit UTF-8 filesystems as well as Windows UTF-16 limits.
  // Keep room in Windows' legacy full-path limit for ordinary share plugins.
  var budget = 230;
  if (Platform.isWindows) {
    final pathBudget = 259 - directory.absolute.path.length - 1;
    if (pathBudget < budget) budget = pathBudget;
  }
  final extension = p.posix.extension(name);
  final stemBudget = budget - utf8.encode(extension).length;
  if (stemBudget < 1) {
    throw ArgumentError.value(
      filename,
      'filename',
      'Share directory and extension leave no room for a file name',
    );
  }
  final stem = name.substring(0, name.length - extension.length);
  var fitted = _truncateUtf8(
    stem,
    stemBudget,
  ).replaceAll(_trailingDotsAndSpaces, '');
  if (fitted.isEmpty) fitted = '_';
  // Device names remain reserved with extensions, and truncation can itself
  // produce a reserved name. Inspect the final first dot-separated component.
  if (_deviceName.hasMatch('$fitted$extension'.split('.').first.trim())) {
    fitted = '_${_truncateUtf8(fitted, stemBudget - 1)}';
  }
  return '$fitted$extension';
}

String _truncateUtf8(String value, int budget) {
  var length = 0;
  final result = StringBuffer();
  for (final rune in value.runes) {
    final character = String.fromCharCode(rune);
    final size = utf8.encode(character).length;
    if (length + size > budget) break;
    result.write(character);
    length += size;
  }
  return result.toString();
}
