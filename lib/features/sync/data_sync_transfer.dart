import 'dart:io';
import 'dart:typed_data';

import 'package:venera_next/network/webdav.dart';

/// Application data participating in archive synchronization.
abstract interface class DataSyncParticipant {
  int? get version;
  String get cachePath;
  Future<int> prepareUploadVersion();
  Future<File> exportData(bool excludeFields);
  Future<bool> importData(File file);
  void notifyImported();
  Future<void> recordSyncTime(int milliseconds);
}

/// A single transfer owns and closes one remote connection.
abstract interface class DataSyncRemote {
  Future<List<String>> listNames();
  Future<void> remove(String name);
  Future<void> write(String name, Uint8List bytes);
  Future<void> readToFile(String name, String path);
  void dispose();
}

abstract interface class DataSyncTransfer {
  Future<void> upload(WebDavEndpoint connection, {required bool excludeFields});

  /// False means no remote update was applied; pending local edits must survive.
  Future<bool> download(WebDavEndpoint connection);
}

class DataSyncArchiveNotFound implements Exception {
  const DataSyncArchiveNotFound();

  @override
  String toString() => 'No data file found';
}

class WebDavDataSyncTransfer implements DataSyncTransfer {
  WebDavDataSyncTransfer({
    required DataSyncParticipant participant,
    required DataSyncRemote Function(WebDavEndpoint) openRemote,
    DateTime Function()? now,
  }) : _participant = participant,
       _openRemote = openRemote,
       _now = now ?? DateTime.now;

  final DataSyncParticipant _participant;
  final DataSyncRemote Function(WebDavEndpoint) _openRemote;
  final DateTime Function() _now;

  @override
  Future<void> upload(
    WebDavEndpoint connection, {
    required bool excludeFields,
  }) async {
    final remote = _openRemote(connection);
    File? archive;
    try {
      final version = await _participant.prepareUploadVersion();
      archive = await _participant.exportData(excludeFields);
      final day = (_now().millisecondsSinceEpoch ~/ 86400000).toString();
      final name = '$day-$version.venera';
      final files = (await remote.listNames())
          .where((name) => name.endsWith('.venera'))
          .toList();
      final today = files.where((name) => name.startsWith('$day-')).firstOrNull;
      // Preserve the existing remote retention protocol during extraction.
      if (today != null) await remote.remove(today);
      if (files.length >= 10) {
        files.sort();
        await remote.remove(files.first);
      }
      await remote.write(name, await archive.readAsBytes());
      await _participant.recordSyncTime(_now().millisecondsSinceEpoch);
    } finally {
      try {
        if (archive != null && await archive.exists()) await archive.delete();
      } finally {
        remote.dispose();
      }
    }
  }

  @override
  Future<bool> download(WebDavEndpoint connection) async {
    final remote = _openRemote(connection);
    Directory? temporary;
    try {
      final files = await remote.listNames();
      files.sort((a, b) => b.compareTo(a));
      final name = files.where((name) => name.endsWith('.venera')).firstOrNull;
      if (name == null) throw const DataSyncArchiveNotFound();
      final parts = name.split('-');
      final version = parts.length > 1
          ? int.tryParse(parts[1].split('.').first)
          : null;
      final current = _participant.version;
      if (version != null && current != null && version <= current) {
        return false;
      }
      temporary = await Directory(
        _participant.cachePath,
      ).createTemp('data-sync-');
      final archive = File('${temporary.path}/snapshot.venera');
      await remote.readToFile(name, archive.path);
      final applied = await _participant.importData(archive);
      if (applied) {
        _participant.notifyImported();
        await _participant.recordSyncTime(_now().millisecondsSinceEpoch);
      }
      return applied;
    } finally {
      try {
        if (temporary != null && await temporary.exists()) {
          await temporary.delete(recursive: true);
        }
      } finally {
        remote.dispose();
      }
    }
  }
}
