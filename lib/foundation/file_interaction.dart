import 'dart:isolate';

import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter/services.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'package:share_plus/share_plus.dart' as s;
import 'package:venera_next/foundation/file_type.dart';
import 'file_save_operation.dart';
import 'platform_dialog_queue.dart';
import 'share_file_operation.dart';

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

class DirectoryPicker {
  /// Pick a directory.
  ///
  /// The directory may not be usable after the instance is GCed.
  DirectoryPicker();

  static final _finalizer = Finalizer<String>((path) {
    if (path.startsWith(App.cachePath)) {
      Directory(path).deleteIgnoreError();
    }
    if (App.isIOS || App.isMacOS) {
      _methodChannel.invokeMethod("stopAccessingSecurityScopedResource");
    }
  });

  static const _methodChannel = MethodChannel("venera/method_channel");

  Future<Directory?> pickDirectory({bool directAccess = false}) async {
    final releaseSelection = IO._beginSelection();
    try {
      String? directory;
      if (App.isWindows || App.isLinux) {
        directory = await file_selector.getDirectoryPath();
      } else if (App.isAndroid) {
        directory = (await AndroidDirectory.pickDirectory())?.path;
        if (directory != null && directAccess) {
          // Native library does not have access to the directory. Copy it to cache.
          var cache = FilePath.join(App.cachePath, "selected_directory");
          if (Directory(cache).existsSync()) {
            Directory(cache).deleteSync(recursive: true);
          }
          Directory(cache).createSync();
          await copyDirectoryIsolate(Directory(directory), Directory(cache));
          directory = cache;
        }
      } else {
        // ios, macos
        directory = await _methodChannel.invokeMethod<String?>(
          "getDirectoryPath",
        );
      }
      if (directory == null) return null;
      _finalizer.attach(this, directory);
      return Directory(directory);
    } finally {
      releaseSelection();
    }
  }
}

class IOSDirectoryPicker {
  static const MethodChannel _channel = MethodChannel("venera/method_channel");

  // 调用 iOS 目录选择方法
  static Future<String?> selectDirectory() async {
    final releaseSelection = IO._beginSelection();
    try {
      final String? path = await _channel.invokeMethod('selectDirectory');
      return path;
    } catch (e) {
      // 返回报错信息
      return e.toString();
    } finally {
      releaseSelection();
    }
  }
}

Future<FileSelectResult?> selectFile({required List<String> ext}) async {
  final releaseSelection = IO._beginSelection();
  try {
    var extensions = App.isMacOS || App.isIOS ? null : ext;
    file_selector.XTypeGroup typeGroup = file_selector.XTypeGroup(
      label: 'files',
      extensions: extensions,
    );
    FileSelectResult? file;
    if (App.isAndroid) {
      const selectFileChannel = MethodChannel("venera/select_file");
      String mimeType = "*/*";
      if (ext.length == 1) {
        mimeType = FileType.fromExtension(ext[0]).mime;
        if (mimeType == "application/octet-stream") {
          mimeType = "*/*";
        }
      }
      var filePath = await selectFileChannel.invokeMethod(
        "selectFile",
        mimeType,
      );
      if (filePath == null) return null;
      file = FileSelectResult(filePath);
    } else {
      var xFile = await file_selector.openFile(
        acceptedTypeGroups: <file_selector.XTypeGroup>[typeGroup],
      );
      if (xFile == null) return null;
      file = FileSelectResult(xFile.path);
    }
    if (!ext.contains(file.path.split(".").last)) {
      if (!App.rootContext.mounted) return null;
      App.rootContext.showMessage(
        message: "Invalid file type: ${file.path.split(".").last}",
      );
      return null;
    }
    return file;
  } finally {
    releaseSelection();
  }
}

Future<List<FileSelection>> selectFiles({
  required List<String> ext,
  List<String>? uniformTypeIdentifiers,
}) async {
  final releaseSelection = IO._beginSelection();
  try {
    if (App.isAndroid) {
      final mimeType = ext.length == 1
          ? FileType.fromExtension(ext.single).mime
          : '*/*';
      final files = await FileSelection._channel.invokeListMethod<dynamic>(
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
  } finally {
    releaseSelection();
  }
}

/// A selection that keeps its file alive until explicitly released.
/// Android document URIs are copied only when the consumer needs the file.
class FileSelection {
  FileSelection(String path)
    : identifier = path,
      name = File(path).name,
      _isDocument = false,
      _file = FileSelectResult(path);

  FileSelection.androidDocument({required String uri, required this.name})
    : identifier = uri,
      _isDocument = true;

  static const _channel = MethodChannel('venera/select_file');

  final String identifier;
  final String name;
  final bool _isDocument;
  FileSelectResult? _file;
  String? _temporaryPath;
  bool _disposed = false;

  Future<File> prepare() async {
    if (_disposed) throw StateError('File selection has been released');
    if (_file == null && _isDocument) {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'prepareFile',
        identifier,
      );
      if (result == null) throw StateError('Failed to prepare selected file');
      final path = result['path'] as String;
      if (result['temporary'] == true) _temporaryPath = path;
      _file = FileSelectResult(path);
    }
    return File(_file!.path);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      if (_temporaryPath != null) {
        await _channel.invokeMethod<void>('releaseFile', _temporaryPath);
      }
    } finally {
      _file = null;
    }
  }
}

Future<String?> selectDirectory() async {
  final releaseSelection = IO._beginSelection();
  try {
    var path = await file_selector.getDirectoryPath();
    return path;
  } finally {
    releaseSelection();
  }
}

// selectDirectoryIOS
Future<String?> selectDirectoryIOS() async {
  return IOSDirectoryPicker.selectDirectory();
}

final _mobileFileSaves = PlatformDialogQueue();

/// Returns `true` if the file was saved, `false` if the user cancelled.
/// The Future includes platform completion and owned temporary-source cleanup.
Future<bool> saveFile({
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
  try {
    return await withSaveFileSource(
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
        await file_selector.XFile(source.path).saveTo(result.path);
        return true;
      },
    );
  } finally {
    releaseSelection();
  }
}

final class _IOOverrides extends IOOverrides {
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

class FileSelectResult {
  final String path;

  static final _finalizer = Finalizer<String>((path) {
    if (path.startsWith(App.cachePath)) {
      File(path).deleteIgnoreError();
    }
  });

  FileSelectResult(this.path) {
    _finalizer.attach(this, path);
  }

  Future<void> saveTo(String path) async {
    await File(this.path).copy(path);
  }

  Future<Uint8List> readAsBytes() {
    return File(path).readAsBytes();
  }

  String get name => File(path).name;
}
