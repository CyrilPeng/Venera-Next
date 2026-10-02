import 'data_sync_archive_order.dart';
import 'dart:async';
import 'package:venera_next/network/request_scope.dart';
import 'package:venera_next/foundation/log.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:venera_next/network/webdav.dart';

/// Application data participating in archive synchronization.
abstract interface class DataSyncParticipant {
  int? get version;
  String get cachePath;
  Future<int> prepareUploadVersion();
  Future<File> exportData(bool excludeFields);
  Future<bool> importData(File file, {required RequestScope scope});
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
  Future<void> upload(
    WebDavEndpoint connection, {
    required bool excludeFields,
    required RequestScope scope,
  });

  /// False means no remote update was applied; pending local edits must survive.
  Future<bool> download(
    WebDavEndpoint connection, {
    required RequestScope scope,
  });
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
    required RequestScope scope,
  }) async {
    scope.check();
    final remote = _openRemote(connection);
    final closeRemote = _closeOnCancel(scope, remote);
    File? archive;
    try {
      final version = await _participant.prepareUploadVersion();
      scope.check();
      archive = await _participant.exportData(excludeFields);
      scope.check();
      final day = (_now().millisecondsSinceEpoch ~/ 86400000).toString();
      final name = '$day-$version.venera';
      final files =
          (await remote.listNames())
              .where((name) => name.endsWith('.venera'))
              .toList()
            ..sort(compareDataSyncArchiveNames);
      scope.check();
      final today = files.where((name) => name.startsWith('$day-')).firstOrNull;
      final bytes = await archive.readAsBytes();
      scope.check();
      // Keep previous recovery points until the new archive is acknowledged.
      // The server may still have committed a request whose response was lost.
      await remote.write(name, bytes);
      scope.check();
      final obsolete = <String>{?today, if (files.length >= 10) files.first}
        ..remove(name);
      for (final oldName in obsolete) {
        scope.check();
        await remote.remove(oldName);
      }
      scope.check();
      await _participant.recordSyncTime(_now().millisecondsSinceEpoch);
    } finally {
      try {
        if (archive != null && await archive.exists()) await archive.delete();
      } finally {
        closeRemote();
      }
    }
  }

  @override
  Future<bool> download(
    WebDavEndpoint connection, {
    required RequestScope scope,
  }) async {
    scope.check();
    final remote = _openRemote(connection);
    final closeRemote = _closeOnCancel(scope, remote);
    Directory? temporary;
    try {
      final files = await remote.listNames();
      scope.check();
      files.sort((a, b) => compareDataSyncArchiveNames(b, a));
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
      scope.check();
      final archive = File('${temporary.path}/snapshot.venera');
      await remote.readToFile(name, archive.path);
      scope.check();
      final applied = await _participant.importData(archive, scope: scope);
      // Once replacement starts, the participant completes commit/rollback.
      // An applied import still emits notifications even if cancellation arrived.
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
        closeRemote();
      }
    }
  }
}

/// Cancel native network work, but keep the operation awaiting its cleanup.
void Function() _closeOnCancel(RequestScope scope, DataSyncRemote remote) {
  var closed = false;
  void close() {
    if (closed) return;
    closed = true;
    remote.dispose();
  }

  unawaited(
    scope.whenCancelled.then((_) {
      try {
        close();
      } catch (error, stack) {
        Log.error('Data Sync cancellation', error, stack);
      }
    }),
  );
  return close;
}
