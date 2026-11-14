import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/routing/cloudflare_verification.dart';

void main() {
  test('only ready documents without challenge markers can be accepted', () {
    for (final (ready, head, body, expected) in [
      (null, null, null, CloudflarePageState.notReady),
      ('loading', '', '<main>Loading</main>', CloudflarePageState.notReady),
      ('complete', null, '<main>Loaded</main>', CloudflarePageState.notReady),
      ('complete', 12, '<main>Loaded</main>', CloudflarePageState.notReady),
      ('complete', '', '', CloudflarePageState.notReady),
      ('complete', '', '<main>Loaded</main>', CloudflarePageState.ready),
      (
        'interactive',
        '#challenge-form',
        '<main>Challenge</main>',
        CloudflarePageState.challenging,
      ),
      (
        'complete',
        '',
        '<script>window._cf_chl_opt = {}</script>',
        CloudflarePageState.challenging,
      ),
    ]) {
      expect(
        cloudflarePageState(readyState: ready, head: head, body: body),
        expected,
      );
    }
  });

  test(
    'not-ready checks stop, then a later callback can finish once',
    () async {
      var state = CloudflarePageState.notReady;
      var reads = 0, saves = 0, passed = 0;
      final verification = CloudflareVerification(
        readinessDelay: Duration.zero,
        readPage: () async {
          reads++;
          return state;
        },
        accept: () async {
          saves++;
          return true;
        },
        isCurrent: () => true,
        onPassed: () => passed++,
        onError: (error, _) => fail('$error'),
      );
      addTearDown(verification.dispose);
      await verification.check();
      expect(reads, 4);
      expect(saves, 0);
      expect(passed, 0);
      state = CloudflarePageState.ready;
      await verification.check();
      await verification.check();
      expect(saves, 1);
      expect(passed, 1);
    },
  );

  test('overlapping load and title callbacks share the pending save', () async {
    final save = Completer<bool>();
    var reads = 0, saves = 0, passed = 0;
    final verification = CloudflareVerification(
      readPage: () async {
        reads++;
        return CloudflarePageState.ready;
      },
      accept: () {
        saves++;
        return save.future;
      },
      isCurrent: () => true,
      onPassed: () => passed++,
      onError: (error, _) => fail('$error'),
    );
    addTearDown(verification.dispose);
    final first = verification.check();
    final second = verification.check();
    await Future<void>.delayed(Duration.zero);
    expect(second, same(first));
    expect(reads, 1);
    expect(saves, 1);
    expect(passed, 0);
    save.complete(true);
    await first;
    expect(passed, 1);
  });

  testWidgets(
    'dismissal cancels readiness waits without another WebView read',
    (tester) async {
      var reads = 0;
      final verification = CloudflareVerification(
        readPage: () async {
          reads++;
          return CloudflarePageState.notReady;
        },
        accept: () async => throw StateError('Document was never ready'),
        isCurrent: () => true,
        onPassed: () => fail('Dismissed verification passed'),
        onError: (error, _) => fail('$error'),
      );
      final checking = verification.check();
      await tester.pump();
      expect(reads, 1);
      verification.dispose();
      await checking;
      await tester.pump(const Duration(seconds: 1));
      expect(reads, 1);
    },
  );

  for (final disposed in [false, true]) {
    test('late saves cannot pass a retired page: disposed=$disposed', () async {
      final save = Completer<bool>();
      var current = true;
      var passed = 0;
      final verification = CloudflareVerification(
        readPage: () async => CloudflarePageState.ready,
        accept: () => save.future,
        isCurrent: () => current,
        onPassed: () => passed++,
        onError: (error, _) => fail('$error'),
      );
      addTearDown(verification.dispose);
      final checking = verification.check();
      await Future<void>.delayed(Duration.zero);
      if (disposed) {
        verification.dispose();
      } else {
        current = false;
      }
      save.complete(true);
      await checking;
      expect(passed, 0);
    });
  }

  test(
    'read and persistence failures remain retryable without passing',
    () async {
      var readFailure = true, saveFailure = true;
      var errors = 0, passed = 0;
      final verification = CloudflareVerification(
        readPage: () async {
          if (readFailure) throw StateError('WebView not available');
          return CloudflarePageState.ready;
        },
        accept: () async {
          if (saveFailure) throw StateError('Cookie persistence failed');
          return true;
        },
        isCurrent: () => true,
        onPassed: () => passed++,
        onError: (_, _) => errors++,
      );
      addTearDown(verification.dispose);
      await verification.check();
      readFailure = false;
      await verification.check();
      expect(errors, 2);
      expect(passed, 0);
      saveFailure = false;
      await verification.check();
      expect(passed, 1);
    },
  );
}
