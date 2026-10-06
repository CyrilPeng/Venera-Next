import 'dart:isolate';
import 'dart:async';

import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter/services.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'package:share_plus/share_plus.dart' as s;
import 'package:venera_next/foundation/file_type.dart';
import 'file_save_operation.dart';
import 'selection_operation.dart';
import 'platform_dialog_queue.dart';
import 'share_file_operation.dart';
import 'file_selection.dart';
import 'directory_selection.dart';
export 'directory_selection.dart';
export 'file_selection.dart';

export 'dart:io';
export 'dart:typed_data';
export 'package:venera_next/foundation/file_system.dart';

class IO {
  /// A global flag used to indicate whether the app is selecting files.
  ///
  /// Select file and other similar file operations will launch external programs,
  /// causing the app to lose focus. AppLifecycleState will be set to paused.
  static bool get isSelectingFiles => _selections.isNotEmpty;

  static final _selections = <Object>{};

  static void Function() _beginSelection() {
    final token = Object();
    _selections.add(token);
    var finished = false;
    return () {
      if (finished) return;
      finished = true;
      Future.delayed(const Duration(milliseconds: 100), () {
        _selections.remove(token);
      });
    };
  }
}

/// Copy the **contents** of the source directory to the destination directory.
/// This function is executed in an isolate to prevent the UI from freezing.
Future<void> copyDirectoryIsolate(
  Directory source,
  Directory destination,
) async {
  await Isolate.run(() => overrideIO(() => copyDirectory(source, destination)));
}

final _directoryDialogs = PlatformDialogQueue();

class DirectoryPicker {
  static const _channel = MethodChannel('venera/method_channel');

  Future<DirectorySelection?> pickDirectory({
    bool directAccess = false,
    void Function()? checkStop,
  }) async {
    checkStop?.call();
    final releaseSelection = IO._beginSelection();
    try {
      return await _directoryDialogs.run(() async {
        checkStop?.call();
        if (App.isAndroid) {
          final directory = await AndroidDirectory.pickDirectory();
          if (directory == null) return null;
          return directAccess
              ? DirectorySelection.copy(
                  source: directory,
                  cacheDirectory: Directory(App.cachePath),
                  copy: copyDirectoryIsolate,
                )
              : DirectorySelection(directory);
        }
        if (App.isIOS || App.isMacOS) {
          final result = await _channel.invokeMapMethod<String, String>(
            'getDirectoryPath',
          );
          if (result == null) return null;
          final path = result['path'];
          final token = result['token'];
          if (path == null || token == null || token.isEmpty) {
            throw StateError('Invalid directory selection receipt');
          }
          return DirectorySelection(
            Directory(path),
            releaseAccess: () =>
                _channel.invokeMethod<void>('releaseDirectoryAccess', token),
            retainAccess: () => _channel.invokeMethod<void>(
              'retainDirectoryAccessForSession',
              token,
            ),
          );
        }
        final path = await file_selector.getDirectoryPath();
        return path == null ? null : DirectorySelection(Directory(path));
      });
    } finally {
      releaseSelection();
    }
  }
}

final _fileDialogs = PlatformDialogQueue();

Future<FileSelection?> selectFile({
  required List<String> ext,
  void Function()? checkStop,
}) async {
  checkStop?.call();
  final releaseSelection = IO._beginSelection();
  try {
    return await _fileDialogs.run(() async {
      checkStop?.call();
      var extensions = App.isMacOS || App.isIOS ? null : ext;
      file_selector.XTypeGroup typeGroup = file_selector.XTypeGroup(
        label: 'files',
        extensions: extensions,
      );
      FileSelection? file;
      if (App.isAndroid) {
        const selectFileChannel = MethodChannel("venera/select_file");
        String mimeType = "*/*";
        if (ext.length == 1) {
          mimeType = FileType.fromExtension(ext[0]).mime;
          if (mimeType == "application/octet-stream") {
            mimeType = "*/*";
          }
        }
        final selected = await selectFileChannel
            .invokeMapMethod<String, dynamic>("selectFile", mimeType);
        if (selected == null) return null;
        file = FileSelection.androidDocument(
          uri: selected['uri'] as String,
          name: selected['name'] as String,
        );
      } else {
        var xFile = await file_selector.openFile(
          acceptedTypeGroups: <file_selector.XTypeGroup>[typeGroup],
        );
        if (xFile == null) return null;
        file = FileSelection(xFile.path);
      }
      if (!ext
          .map((value) => value.toLowerCase())
          .contains(file.name.split('.').last.toLowerCase())) {
        await file.dispose();
        throw FormatException(
          'Invalid file type: ${file.name.split('.').last}',
        );
      }
      return file;
    });
  } finally {
    releaseSelection();
  }
}

Future<List<FileSelection>> selectFiles({
  required List<String> ext,
  List<String>? uniformTypeIdentifiers,
  void Function()? checkStop,
}) async {
  checkStop?.call();
  final releaseSelection = IO._beginSelection();
  try {
    return await _fileDialogs.run(() async {
      checkStop?.call();
      if (App.isAndroid) {
        final mimeType = ext.length == 1
            ? FileType.fromExtension(ext.single).mime
            : '*/*';
        final files = await const MethodChannel('venera/select_file')
            .invokeListMethod<dynamic>(
              'selectFiles',
              mimeType == 'application/octet-stream' ? '*/*' : mimeType,
            );
        return [
          for (final file in files ?? const [])
            FileSelection.androidDocument(
              uri: file['uri'] as String,
              name: file['name'] as String,
            ),
        ];
      }
      final files = await file_selector.openFiles(
        acceptedTypeGroups: [
          file_selector.XTypeGroup(
            label: 'files',
            extensions: App.isIOS || App.isMacOS ? null : ext,
            uniformTypeIdentifiers: uniformTypeIdentifiers,
          ),
        ],
      );
      return files.map((file) => FileSelection(file.path)).toList();
    });
  } finally {
    releaseSelection();
  }
}

final _mobileFileSaves = PlatformDialogQueue();

/// Returns `true` if the file was saved, `false` if the user cancelled.
/// The caller's operation joins platform completion and source cleanup.
Future<bool> saveFile({
  required SelectionOperation operation,
  Uint8List? data,
  required String filename,
  File? file,
  void Function()? checkStop,
}) async {
  checkStop?.call();
  if (data == null && file == null) {
    throw Exception("data and file cannot be null at the same time");
  }
  final releaseSelection = IO._beginSelection();
  unawaited(operation.settled.then((_) => releaseSelection()));
  return await withSaveFileSource(
    operation: operation,
    data: data,
    file: file,
    filename: filename,
    cacheDirectory: Directory(App.cachePath),
    // iOS's fileName parameter creates/deletes a fixed temporary path. Export
    // our uniquely owned source with the correct basename instead, including
    // when the original file belongs to a caller.
    copySource: App.isMobile,
    checkStop: checkStop,
    save: (source) async {
      if (App.isMobile) {
        return _mobileFileSaves.run(() async {
          operation.checkActive();
          checkStop?.call();
          final result = await FlutterFileDialog.saveFile(
            params: SaveFileDialogParams(sourceFilePath: source.path),
          );
          return result != null;
        });
      }
      final result = await file_selector.getSaveLocation(
        suggestedName: filename,
      );
      if (result == null) return false;
      operation.checkActive();
      checkStop?.call();
      await file_selector.XFile(source.path).saveTo(result.path);
      return true;
    },
  );
}

final class _IOOverrides extends IOOverrides {
  final _parentZone = Zone.current;

  // Only file/directory construction is overridden for SAF. Preserve native
  // type queries through the parent zone: Dart 3.11's default IOOverrides
  // adapter can report existing Windows paths as notFound.
  @override
  Future<FileSystemEntityType> fseGetType(String path, bool followLinks) =>
      _parentZone.run(
        () => FileSystemEntity.type(path, followLinks: followLinks),
      );

  @override
  FileSystemEntityType fseGetTypeSync(String path, bool followLinks) =>
      _parentZone.run(
        () => FileSystemEntity.typeSync(path, followLinks: followLinks),
      );

  @override
  Directory createDirectory(String path) {
    if (App.isAndroid) {
      var dir = AndroidDirectory.fromPathSync(path);
      if (dir == null) {
        return super.createDirectory(path);
      }
      return dir;
    } else {
      return super.createDirectory(path);
    }
  }

  @override
  File createFile(String path) {
    if (path.startsWith("file://")) {
      path = path.substring(7);
    }
    if (App.isAndroid) {
      var f = AndroidFile.fromPathSync(path);
      if (f == null) {
        return super.createFile(path);
      }
      return f;
    } else {
      return super.createFile(path);
    }
  }
}

T overrideIO<T>(T Function() f) {
  return IOOverrides.runWithIOOverrides<T>(f, _IOOverrides());
}

class Share {
  static final _dialogs = PlatformDialogQueue();

  static Future<void> shareFile({
    required Uint8List data,
    required String filename,
    required String mime,
    Rect? origin,
    Rect Function()? resolveOrigin,
    void Function()? checkStop,
  }) => _dialogs.run(() async {
    checkStop?.call();
    if (App.isLinux) {
      throw UnsupportedError('File sharing is unavailable on Linux');
    }
    Rect? actualOrigin;
    await withShareFileSource(
      data: data,
      filename: filename,
      cacheDirectory: Directory(FilePath.join(App.cachePath, 'shares')),
      // Android copies the input before acknowledging the method. The other
      // platforms can pass its URL/path to a receiver after acknowledgment.
      retainAfterDispatch: !App.isAndroid,
      checkStop: () {
        checkStop?.call();
        actualOrigin = resolveOrigin?.call() ?? origin;
      },
      share: (source) => s.SharePlus.instance.share(
        s.ShareParams(
          files: [s.XFile(source.path, mimeType: mime)],
          title: source.name,
          sharePositionOrigin: actualOrigin,
        ),
      ),
    );
  });

  static Future<void> shareText(
    String text, {
    Rect? origin,
    Rect Function()? resolveOrigin,
    bool Function()? canShare,
  }) => _dialogs.run(() async {
    if (canShare?.call() == false) return;
    await s.SharePlus.instance.share(
      s.ShareParams(
        text: text,
        sharePositionOrigin: resolveOrigin?.call() ?? origin,
      ),
    );
  });
}
