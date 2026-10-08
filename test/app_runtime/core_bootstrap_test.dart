import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/core_bootstrap.dart';
import 'package:venera_next/app_runtime/headless_bindings.dart';
import 'package:venera_next/foundation/js_engine.dart';

void main() {
  test(
    'concurrent startup shares work and waits for settings before sources',
    () async {
      final ready = Completer<void>();
      final events = <String>[];
      final bootstrap = CoreBootstrap(
        environment: () async {
          events.add('environment');
        },
        settings: () async {
          events.add('settings');
          await ready.future;
        },
        infrastructure: () async {
          events.add('infrastructure');
        },
        sources: () async {
          events.add('sources');
        },
        stores: () async {
          events.add('stores');
        },
        finish: () async {
          events.add('finish');
        },
      );
      final first = bootstrap.start();
      expect(identical(first, bootstrap.start()), isTrue);
      await pumpEventQueue();
      expect(events, ['environment', 'settings']);
      ready.complete();
      await first;
      await bootstrap.start();
      expect(events, [
        'environment',
        'settings',
        'infrastructure',
        'sources',
        'stores',
        'finish',
      ]);
    },
  );

  test(
    'source startup failure never launches stores waiting for source readiness',
    () async {
      final error = StateError('engine unavailable');
      var storesStarted = false;
      final bootstrap = CoreBootstrap(
        environment: () async {},
        settings: () async {},
        infrastructure: () async {},
        sources: () async => throw error,
        stores: () async {
          storesStarted = true;
        },
        finish: () async => fail('Failed startup cannot finish'),
      );
      await expectLater(bootstrap.start(), throwsA(same(error)));
      await expectLater(bootstrap.start(), throwsA(same(error)));
      expect(storesStarted, isFalse);
    },
  );

  test('headless UI requests fail explicitly without a navigator', () {
    final engine = JsEngine.create();
    addTearDown(engine.closeAndWait);
    expect(
      () => const HeadlessJsUiHandler().handleUIMessage({
        'function': 'showDialog',
      }, engine: engine),
      throwsUnsupportedError,
    );
  });
}
