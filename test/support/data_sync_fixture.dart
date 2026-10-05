import 'package:venera_next/network/request_scope.dart';
import 'dart:async';
import 'package:venera_next/features/sync/data_sync_controller.dart';
import 'package:venera_next/features/sync/data_sync_transfer.dart';
import 'package:venera_next/features/sync/data_sync_recovery.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/sync_preference_store.dart';
import 'package:venera_next/network/webdav.dart';

/// Instance-local ports for exercising the real controller transfer path.
class SyncTestFixture {
  SyncTestFixture({
    SyncPreferenceStore? preferences,
    Future<void> Function()? saveSettings,
    FutureOr<void> Function()? persistImplicit,
    void Function() Function(void Function())? observeChanges,
    DateTime Function()? now,
    Timer Function(Duration, void Function())? createTimer,
    DataSyncImportRecovery? importRecovery,
  }) {
    final settings = <String, dynamic>{
      'webdav': ['https://example.com/dav', 'user', 'password'],
    };
    final implicit = <String, dynamic>{'webdavSyncMode': 'manual'};
    _create = () => DataSyncController(
      preferences:
          preferences ??
          SyncPreferenceStore(
            readSetting: (key) => settings[key],
            writeSetting: (key, value) => settings[key] = value,
            implicitData: () => implicit,
          ),
      transfer: () => transfer,
      saveSettings: saveSettings ?? () async {},
      persistImplicit: persistImplicit ?? () {},
      observeChanges: observeChanges ?? (_) => () {},
      now: now,
      createTimer: createTimer,
      importRecovery: importRecovery,
    );
  }

  final transfer = ControlledSyncTransfer();
  late final DataSyncController Function() _create;
  DataSyncController? _controller;
  DataSyncController get controller => _controller ??= _create();

  void disposeController() {
    _controller?.dispose();
    _controller = null;
  }
}

class ControlledSyncTransfer implements DataSyncTransfer {
  Future<Res<bool>> Function() onUpload = () async => const Res(true);
  Future<Res<bool>> Function() onDownload = () async => const Res(false);
  void Function()? onImported;
  String? uploadOperationId;
  String? downloadOperationId;

  @override
  Future<void> upload(
    WebDavEndpoint connection, {
    required bool excludeFields,
    required RequestScope scope,
    String? syncOperationId,
  }) async {
    uploadOperationId = syncOperationId;
    final result = await onUpload();
    if (result.error) throw _TransferFailure(result.errorMessage!);
  }

  @override
  Future<bool> download(
    WebDavEndpoint connection, {
    required RequestScope scope,
    void Function(void Function())? publishImported,
    String? syncOperationId,
  }) async {
    downloadOperationId = syncOperationId;
    final result = await onDownload();
    if (result.error) throw _TransferFailure(result.errorMessage!);
    final notify = onImported;
    if (result.data && notify != null) {
      if (publishImported != null) {
        publishImported(notify);
      } else {
        notify();
      }
    }
    return result.data;
  }
}

class _TransferFailure implements Exception {
  const _TransferFailure(this.message);
  final String message;
  @override
  String toString() => message;
}
