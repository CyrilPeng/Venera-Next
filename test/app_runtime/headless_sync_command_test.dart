import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/headless_sync_command.dart';
import 'package:venera_next/foundation/res.dart';
import '../support/data_sync_fixture.dart';

void main() {
  for (final command in ['up', 'down']) {
    test(
      '$command waits for service completion before emitting success',
      () async {
        final fixture = SyncTestFixture();
        addTearDown(fixture.disposeController);
        final gate = Completer<Res<bool>>();
        var calls = 0;
        Future<Res<bool>> transfer() {
          calls++;
          return gate.future;
        }

        fixture.transfer.onUpload = transfer;
        fixture.transfer.onDownload = transfer;
        final messages = <Map<String, dynamic>>[];
        final completed = runHeadlessSyncCommand(
          command,
          isConfigured: fixture.controller.hasConfiguration,
          upload: fixture.controller.uploadData,
          download: fixture.controller.downloadData,
          emit: messages.add,
        );
        expect(calls, 1);
        expect(messages.map((message) => message['status']), ['running']);
        gate.complete(const Res(true));
        expect(await completed, 0);
        expect(messages.map((message) => message['status']), [
          'running',
          'success',
        ]);
        expect(
          messages.last['message'],
          command == 'up' ? 'Upload complete.' : 'Download complete.',
        );
      },
    );

    test(
      '$command service failure cannot emit success or return zero',
      () async {
        final fixture = SyncTestFixture();
        addTearDown(fixture.disposeController);
        fixture.transfer.onUpload = () async => const Res.error('denied');
        fixture.transfer.onDownload = () async => const Res.error('denied');
        final messages = <Map<String, dynamic>>[];
        expect(
          await runHeadlessSyncCommand(
            command,
            isConfigured: fixture.controller.hasConfiguration,
            upload: fixture.controller.uploadData,
            download: fixture.controller.downloadData,
            emit: messages.add,
          ),
          1,
        );
        expect(messages.map((message) => message['status']), [
          'running',
          'error',
        ]);
        expect(messages.last['message'], contains('denied'));
      },
    );
  }

  for (final command in [null, 'invalid', 'up', 'down']) {
    test(
      'missing configuration or invalid command never invokes service: $command',
      () async {
        final messages = <Map<String, dynamic>>[];
        Future<Res<bool>> unexpected() async =>
            throw StateError('must not run');
        expect(
          await runHeadlessSyncCommand(
            command,
            isConfigured: false,
            upload: unexpected,
            download: unexpected,
            emit: messages.add,
          ),
          1,
        );
        expect(messages, hasLength(1));
        expect(messages.single['status'], 'error');
        expect(
          messages.single['message'],
          command == 'up' || command == 'down'
              ? 'WebDAV sync is not configured.'
              : 'Invalid webdav command. Use "up" or "down".',
        );
      },
    );
  }

  test('unexpected service exceptions become terminal errors', () async {
    final messages = <Map<String, dynamic>>[];
    expect(
      await runHeadlessSyncCommand(
        'up',
        isConfigured: true,
        upload: () => throw StateError('unexpected'),
        download: () async => const Res(true),
        emit: messages.add,
      ),
      1,
    );
    expect(messages.map((message) => message['status']), ['running', 'error']);
    expect(messages.last['message'], contains('unexpected'));
  });

  test('a successful no-op download remains successful', () async {
    final messages = <Map<String, dynamic>>[];
    expect(
      await runHeadlessSyncCommand(
        'down',
        isConfigured: true,
        upload: () async => const Res(true),
        download: () async => const Res(false),
        emit: messages.add,
      ),
      0,
    );
    expect(messages.last, {
      'status': 'success',
      'message': 'Download complete.',
    });
  });
}
