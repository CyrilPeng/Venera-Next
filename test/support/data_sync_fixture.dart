import 'dart:async';
import 'package:venera_next/features/sync/data_sync_controller.dart';
import 'package:venera_next/features/sync/data_sync_transfer.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/sync_preference_store.dart';
import 'package:venera_next/network/webdav.dart';

/// Instance-local ports for exercising the real controller transfer path.
class SyncTestFixture {
  SyncTestFixture({
    SyncPreferenceStore? preferences,
    Future<void> Function()? saveSettings,
    void Function()? persistImplicit,
    void Function() Function(void Function())? observeChanges,
    DateTime Function()? now,
    Timer Function(Duration, void Function())? createTimer,
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

  @override
  Future<void> upload(
    WebDavEndpoint connection, {
    required bool excludeFields,
  }) async {
    final result = await onUpload();
    if (result.error) throw _TransferFailure(result.errorMessage!);
  }

  @override
  Future<bool> download(WebDavEndpoint connection) async {
    final result = await onDownload();
    if (result.error) throw _TransferFailure(result.errorMessage!);
    return result.data;
  }
}

class _TransferFailure implements Exception {
  const _TransferFailure(this.message);
  final String message;
  @override
  String toString() => message;
}
