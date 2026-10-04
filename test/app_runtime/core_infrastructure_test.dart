import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/core_infrastructure.dart';
import 'package:venera_next/network/cookie_jar.dart';

void main() {
  late Directory root;
  late SingleInstanceCookieJar? previous;
  final uri = Uri.parse('https://example.com/');

  setUp(() {
    root = Directory.systemTemp.createTempSync('core-infrastructure-');
    previous = SingleInstanceCookieJar.instance;
    SingleInstanceCookieJar.instance = null;
  });
  tearDown(() async {
    SingleInstanceCookieJar.instance?.dispose();
    SingleInstanceCookieJar.instance = previous;
    await root.delete(recursive: true);
  });

  test(
    'failure joins late services before closing newly opened cookies',
    () async {
      final entered = Completer<void>();
      final delayed = Completer<void>();
      final failure = StateError('network runtime unavailable');
      late SingleInstanceCookieJar cookies;
      var lateServiceFinished = false;
      final starting = initializeCoreInfrastructure(
        directory: root.path,
        services: [
          () => throw failure,
          () async {
            cookies = SingleInstanceCookieJar.instance!;
            entered.complete();
            await delayed.future;
            cookies.saveFromResponse(uri, [Cookie('session', 'retained')]);
            lateServiceFinished = true;
          },
        ],
      );
      final checked = expectLater(starting, throwsA(same(failure)));
      await entered.future;
      await pumpEventQueue();
      expect(SingleInstanceCookieJar.instance, same(cookies));
      expect(cookies.loadForRequest(uri), isEmpty);
      delayed.complete();
      await checked;
      expect(lateServiceFinished, isTrue);
      expect(SingleInstanceCookieJar.instance, isNull);
      expect(() => cookies.loadForRequest(uri), throwsStateError);
      final reopened = await SingleInstanceCookieJar.createInstance(
        directory: root.path,
      );
      expect(reopened.loadForRequest(uri).single.value, 'retained');
    },
  );

  test('failed services do not close a borrowed cookie database', () async {
    final cookies = await SingleInstanceCookieJar.createInstance(
      directory: root.path,
    );
    await expectLater(
      initializeCoreInfrastructure(
        directory: root.path,
        services: [() async => throw StateError('failed')],
      ),
      throwsStateError,
    );
    expect(SingleInstanceCookieJar.instance, same(cookies));
    cookies.saveFromResponse(uri, [Cookie('session', 'existing')]);
    expect(cookies.loadForRequest(uri).single.value, 'existing');
  });

  test('successful services retain the cookie database for the host', () async {
    await initializeCoreInfrastructure(
      directory: root.path,
      services: [
        () => SingleInstanceCookieJar.instance!.saveFromResponse(uri, [
          Cookie('session', 'ready'),
        ]),
        () async => await Future<void>.value(),
      ],
    );
    expect(
      SingleInstanceCookieJar.instance!.loadForRequest(uri).single.value,
      'ready',
    );
  });
}
