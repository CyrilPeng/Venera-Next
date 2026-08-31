import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/app_runtime.dart';

void main() {
  test('Bangumi startup waits for data sync before initialization', () async {
    final download = Completer<void>();
    final events = <String>[];
    var initializerCreated = false;

    final initialization = initializeBangumiAfterDataSync(
      waitForDownload: () async {
        events.add('download-started');
        await download.future;
        events.add('download-finished');
      },
      createInitializer: () {
        initializerCreated = true;
        return () async => events.add('bangumi-initialized');
      },
    );
    await Future<void>.delayed(Duration.zero);

    expect(events, ['download-started']);
    expect(initializerCreated, isFalse);
    download.complete();
    await initialization;
    expect(initializerCreated, isTrue);
    expect(events, [
      'download-started',
      'download-finished',
      'bangumi-initialized',
    ]);
  });

  test('Bangumi startup does not wait for network initialization', () async {
    final initialization = Completer<void>();
    var started = false;

    startBangumiAfterDataSync(
      waitForDownload: () async {},
      createInitializer: () {
        return () {
          started = true;
          return initialization.future;
        };
      },
    );
    await Future<void>.delayed(Duration.zero);

    expect(started, isTrue);
    expect(initialization.isCompleted, isFalse);
    initialization.complete();
    await Future<void>.delayed(Duration.zero);
  });
}
