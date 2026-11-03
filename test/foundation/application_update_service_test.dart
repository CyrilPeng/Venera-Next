import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/application_update_service.dart';
import 'package:venera_next/foundation/operation_failure.dart';
import 'package:venera_next/network/app_dio.dart';
import 'package:venera_next/network/request_scope.dart';

import '../support/application_update_adapter.dart';

void main() {
  for (final tv in [false, true]) {
    test('only TV checks require an uploaded TV package; TV=$tv', () async {
      final adapter = ApplicationUpdateAdapter()..released.complete();
      final service = ApplicationUpdateService(
        forAndroidTv: tv,
        createClient: () => Dio()..httpClientAdapter = adapter,
        currentVersion: () => '1.0.0',
      );
      final checked = service.check();
      await adapter.entered.future;
      adapter.complete({
        'tag_name': 'v2.0.0',
        'assets': [
          {
            'name': 'VeneraNext-2.0.0-android.apk',
            'state': 'uploaded',
            'size': 20,
          },
        ],
      });
      expect(await checked, tv ? isNull : '2.0.0');
      await service.closeAndWait();
      await expectLater(service.check(), throwsStateError);
    });
  }

  test(
    'TV previews skip mobile-only releases and preserve channel ordering',
    () async {
      final adapter = ApplicationUpdateAdapter()..released.complete();
      final service = ApplicationUpdateService(
        forAndroidTv: true,
        createClient: () => Dio()..httpClientAdapter = adapter,
        currentVersion: () => '1.18.2-rc.1',
      );
      final checked = service.check();
      await adapter.entered.future;
      Map<String, Object> release(String version, {bool draft = false}) => {
        'tag_name': 'v$version',
        'draft': draft,
        'prerelease': true,
        'assets': [
          {
            'name': 'VeneraNext-$version-android-tv.apk',
            'state': 'uploaded',
            'size': 20,
          },
        ],
      };
      adapter.complete([
        {'tag_name': 'v1.18.2-rc.9', 'prerelease': true},
        release('1.18.2-rc.8', draft: true),
        release('1.18.2-rc.7'),
        release('1.18.2-rc.2'),
      ]);
      expect(adapter.paths.single, endsWith('releases?per_page=20'));
      expect(await checked, '1.18.2-rc.7');
      await service.closeAndWait();
    },
  );

  for (final asset in <Object?>[
    null,
    {
      'name': 'VeneraNext-TV-2.0.0-alpha.19.2-abcdef-universal.apk',
      'state': 'uploaded',
      'size': 20,
    },
    {
      'name': 'VeneraNext-2.0.0-android-tv-arm64-v8a.apk',
      'state': 'uploaded',
      'size': 20,
    },
    {
      'name': 'VeneraNext-1.0.0-android-tv.apk',
      'state': 'uploaded',
      'size': 20,
    },
    {'name': 'VeneraNext-2.0.0-android-tv.apk', 'state': 'starter', 'size': 20},
    {'name': 'VeneraNext-2.0.0-android-tv.apk', 'state': 'uploaded', 'size': 0},
  ]) {
    test('TV rejects incompatible or incomplete packages: $asset', () async {
      final adapter = ApplicationUpdateAdapter()..released.complete();
      final service = ApplicationUpdateService(
        forAndroidTv: true,
        createClient: () => Dio()..httpClientAdapter = adapter,
        currentVersion: () => '1.0.0',
      );
      final checked = service.check();
      await adapter.entered.future;
      adapter.complete({
        'tag_name': 'v2.0.0',
        'assets': [asset],
      });
      expect(await checked, isNull);
      await service.closeAndWait();
    });
  }

  test(
    'stable and preview requests preserve channel selection and wait for cleanup',
    () async {
      for (final current in ['1.10.0', '1.11.0-rc.1']) {
        final adapter = ApplicationUpdateAdapter();
        final service = ApplicationUpdateService(
          createClient: () => Dio()..httpClientAdapter = adapter,
          currentVersion: () => current,
        );
        var finished = false;
        final result = service.check().whenComplete(() => finished = true);
        await adapter.entered.future;
        expect(
          adapter.paths.single.endsWith('releases/latest'),
          current == '1.10.0',
        );
        adapter.complete([
          {'tag_name': 'v1.12.0', 'draft': true},
          {'tag_name': 'v1.11.0-rc.2', 'prerelease': true},
          {'tag_name': 'v1.10.1'},
        ]);
        await adapter.draining.future;
        expect(finished, isFalse);
        adapter.released.complete();
        expect(await result, current == '1.10.0' ? '1.10.1' : '1.11.0-rc.2');
        await service.closeAndWait();
        expect(adapter.closes, 1);
      }
    },
  );

  test(
    'one consumer cancels without cancelling siblings or losing retired cleanup',
    () async {
      final adapters = <ApplicationUpdateAdapter>[];
      final service = ApplicationUpdateService(
        createClient: () {
          final adapter = ApplicationUpdateAdapter();
          adapters.add(adapter);
          return Dio()..httpClientAdapter = adapter;
        },
        currentVersion: () => '1.0.0',
      );
      final parent = RequestScope();
      final firstScope = RequestScope(parent: parent);
      final first = expectLater(
        service.check(scope: firstScope),
        throwsA(isA<RequestCancelled>()),
      );
      final second = expectLater(
        service.check(scope: parent),
        throwsA(isA<RequestCancelled>()),
      );
      await pumpEventQueue();
      firstScope.cancel();
      await adapters.first.draining.future;
      expect(parent.isCancelled, isFalse);
      expect(adapters.last.draining.isCompleted, isFalse);
      var finished = false;
      final close = service.closeAndWait();
      expect(identical(close, service.closeAndWait()), isTrue);
      final closing = close.then((_) => finished = true);
      await adapters.last.draining.future;
      adapters.last.released.complete();
      await pumpEventQueue();
      expect(finished, isFalse);
      adapters.first.released.complete();
      await Future.wait([first, second, closing]);
      await expectLater(service.check(), throwsStateError);
      expect(parent.isCancelled, isFalse);
      firstScope.dispose();
      parent.dispose();
    },
  );

  test(
    'cancellation during successful response cleanup cannot publish an update',
    () async {
      final adapter = ApplicationUpdateAdapter();
      final service = ApplicationUpdateService(
        createClient: () => Dio()..httpClientAdapter = adapter,
        currentVersion: () => '1.0.0',
      );
      final checked = expectLater(
        service.check(),
        throwsA(isA<RequestCancelled>()),
      );
      await adapter.entered.future;
      adapter.complete({'tag_name': 'v2.0.0'});
      await adapter.draining.future;
      final closing = service.closeAndWait();
      adapter.released.complete();
      await Future.wait([checked, closing]);
    },
  );

  for (final invalid in <Object>[
    'not a release document',
    {'message': 'upstream error'},
    [
      {'tag_name': ''},
    ],
    [null],
  ]) {
    test(
      'malformed metadata remains a failure rather than no update: $invalid',
      () async {
        final adapter = ApplicationUpdateAdapter()..released.complete();
        final service = ApplicationUpdateService(
          createClient: () => Dio()..httpClientAdapter = adapter,
          currentVersion: () => '1.0.0',
        );
        final checked = expectLater(
          service.check(),
          throwsA(
            isA<OperationFailure>().having(
              (failure) => failure.cause,
              'cause',
              isA<FormatException>(),
            ),
          ),
        );
        await adapter.entered.future;
        adapter.complete(invalid);
        await checked;
        await service.closeAndWait();
        expect(adapter.closes, 1);
      },
    );
  }

  test(
    'operation and both close failures stay inspectable after repeated close',
    () async {
      final operationError = StateError('HTTP failed');
      final closeError = StateError('adapter close');
      final idleError = StateError('native idle');
      final adapter = ApplicationUpdateAdapter()..closeError = closeError;
      final service = ApplicationUpdateService(
        createClient: () => Dio()..httpClientAdapter = adapter,
        currentVersion: () => '1.0.0',
      );
      final checked = expectLater(
        service.check(),
        throwsA(
          isA<ApplicationUpdateCleanupFailure>()
              .having(
                (e) => (e.cause as DioException).error,
                'operation',
                same(operationError),
              )
              .having((e) => e.stackTrace, 'original stack', isNotNull)
              .having((e) => e.failures.map((f) => f.error), 'cleanup', [
                closeError,
                idleError,
              ]),
        ),
      );
      await adapter.entered.future;
      adapter.response.completeError(operationError);
      await adapter.draining.future;
      adapter.released.completeError(idleError);
      await checked;
      final closing = service.closeAndWait();
      await expectLater(
        closing,
        throwsA(isA<ApplicationUpdateCleanupFailure>()),
      );
      expect(identical(closing, service.closeAndWait()), isTrue);
      expect(adapter.closes, 1);
    },
  );

  test(
    'synchronous client factory reentry closes its registered request',
    () async {
      late ApplicationUpdateService service;
      late Future<void> closing;
      final adapter = ApplicationUpdateAdapter();
      service = ApplicationUpdateService(
        createClient: () {
          closing = service.closeAndWait();
          return Dio()..httpClientAdapter = adapter;
        },
        currentVersion: () => '1.0.0',
      );
      final checked = expectLater(
        service.check(),
        throwsA(isA<RequestCancelled>()),
      );
      await adapter.draining.future;
      expect(adapter.entered.isCompleted, isFalse);
      adapter.released.complete();
      await Future.wait([checked, closing]);
    },
  );
}
