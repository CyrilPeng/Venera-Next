import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:path/path.dart' as p;
import 'package:rhttp/rhttp.dart';

import 'file_selection.dart';
import 'directory_selection.dart';

/// The experimental HAP owns this channel; other platforms never call it.
abstract final class HarmonyOS {
  @visibleForTesting
  static bool? debugIsCurrent;

  static bool get isCurrent {
    var current = Platform.operatingSystem == 'ohos';
    assert(() {
      current = debugIsCurrent ?? current;
      return true;
    }());
    return current;
  }

  static const channel = MethodChannel('venera/harmonyos');

  static Future<({String data, String cache})> directories() async {
    final result = await channel.invokeMapMethod<String, String>('directories');
    final data = result?['data'];
    final cache = result?['cache'];
    if (data == null ||
        cache == null ||
        !_localPath(data) ||
        !_localPath(cache)) {
      throw StateError('Invalid HarmonyOS sandbox directories');
    }
    await Directory(data).create(recursive: true);
    await Directory(cache).create(recursive: true);
    return (data: data, cache: cache);
  }

  static bool _localPath(String value) =>
      p.isAbsolute(value) && !value.contains('://');

  static Future<void> initializeHttp() => isCurrent
      ? Rhttp.init(externalLibrary: ExternalLibrary.open('librhttp.so'))
      : Rhttp.init();

  static Future<DirectorySelection?> selectDirectory({
    required String cachePath,
    void Function(int processed, int total)? onCopyProgress,
  }) async {
    final result = await channel.invokeMapMethod<String, Object?>(
      'selectDirectory',
    );
    if (result == null) return null;
    final path = result['path'];
    final token = result['token'];
    final name = result['name'];
    if (path is! String ||
        token is! String ||
        name is! String ||
        !RegExp(r'^[0-9a-f-]{36}$').hasMatch(token) ||
        name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains(RegExp(r'[\\/\x00]')) ||
        !_localPath(path) ||
        !p.equals(
          path,
          p.join(cachePath, 'selected_directories', token, 'contents', name),
        )) {
      throw StateError('Invalid HarmonyOS owned directory receipt');
    }
    return DirectorySelection.ownedCopy(
      directory: Directory(path),
      token: token,
      prepare: (receipt) => _prepareDirectory(receipt, onCopyProgress),
      release: (receipt) =>
          channel.invokeMethod<void>('releaseDirectory', receipt),
    );
  }

  static Future<void> _prepareDirectory(
    Map<String, String> receipt,
    void Function(int, int)? onProgress,
  ) async {
    var active = true;
    var polling = false;
    Future<void> poll() async {
      if (!active || polling) return;
      polling = true;
      try {
        final progress = await channel.invokeMapMethod<String, Object?>(
          'directoryCopyProgress',
          receipt,
        );
        final processed = progress?['processed'];
        final total = progress?['total'];
        if (active &&
            processed is num &&
            total is num &&
            processed.isFinite &&
            total.isFinite &&
            processed >= 0 &&
            total >= processed) {
          onProgress?.call(processed.toInt(), total.toInt());
        }
      } catch (_) {
        // Progress is advisory; only the actual copy decides success or failure.
      } finally {
        polling = false;
      }
    }

    final timer = onProgress == null
        ? null
        : Timer.periodic(
            const Duration(milliseconds: 250),
            (_) => unawaited(poll()),
          );
    try {
      await channel.invokeMethod<void>('prepareDirectory', receipt);
    } finally {
      active = false;
      timer?.cancel();
    }
  }

  static Future<List<FileSelection>> selectFiles({
    required List<String> extensions,
    required String cachePath,
    bool multiple = false,
  }) async {
    final result = await channel.invokeListMethod<Object?>('selectFiles', {
      'extensions': extensions,
      'multiple': multiple,
    });
    final files = <FileSelection>[];
    try {
      for (final value in result ?? const []) {
        if (value is! Map) throw StateError('Invalid HarmonyOS file receipt');
        final path = value['path'];
        final token = value['token'];
        final name = value['name'];
        if (path is! String ||
            token is! String ||
            name is! String ||
            !RegExp(r'^[0-9a-f-]{36}$').hasMatch(token) ||
            name.isEmpty ||
            p.basename(name) != name ||
            !_localPath(path) ||
            !p.equals(path, p.join(cachePath, 'selected_files', token, name))) {
          throw StateError('Invalid HarmonyOS owned file receipt');
        }
        files.add(
          FileSelection.ownedCopy(
            path: path,
            name: name,
            token: token,
            release: (receipt) =>
                channel.invokeMethod<void>('releaseFile', receipt),
          ),
        );
      }
      if (!multiple && files.length > 1) {
        throw StateError('Multiple files returned for a single selection');
      }
      for (final file in files) {
        final suffix = p.extension(file.name);
        if (!extensions
            .map((e) => e.toLowerCase())
            .contains(
              suffix.isEmpty ? '' : suffix.substring(1).toLowerCase(),
            )) {
          throw FormatException('Invalid selected file type: ${file.name}');
        }
      }
      return files;
    } catch (_) {
      await Future.wait(files.map((file) => file.dispose()));
      rethrow;
    }
  }

  static Future<bool> saveFile(File source) async =>
      await channel.invokeMethod<bool>('saveFile', {
        'path': source.path,
        'name': p.basename(source.path),
      }) ??
      false;

  static Future<void> setScreenAwake(bool value) =>
      channel.invokeMethod<void>('setScreenAwake', {'awake': value});
}
