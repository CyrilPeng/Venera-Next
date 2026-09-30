import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/init.dart';

class _Service with Init {
  _Service(this.initialize);
  Future<void> Function() initialize;
  int calls = 0;
  @override
  Future<void> doInit() {
    calls++;
    return initialize();
  }
}

void main() {
  test(
    'waiters do not start work and concurrent initialization executes once',
    () async {
      final gate = Completer<void>();
      final service = _Service(() => gate.future);
      final waiting = service.ensureInit();
      expect(service.initializationState, InitializationState.notStarted);
      expect(service.calls, 0);
      final first = service.init();
      final second = service.init();
      expect(identical(waiting, first), isTrue);
      expect(identical(first, second), isTrue);
      expect(service.calls, 1);
      expect(service.initializationState, InitializationState.initializing);
      expect(identical(service.retryInit(), first), isTrue);
      gate.complete();
      await Future.wait([waiting, first, second]);
      expect(service.initializationState, InitializationState.ready);
      await service.init();
      await service.retryInit();
      expect(service.calls, 1);
    },
  );

  test(
    'failure reaches existing waiters and remains cached until explicit retry',
    () async {
      final gate = Completer<void>();
      final service = _Service(() => gate.future);
      final error = StateError('failed');
      final trace = StackTrace.current;
      final waiting = service.ensureInit();
      final waiterCheck = expectLater(waiting, throwsA(same(error)));
      final first = service.init();
      final callerCheck = expectLater(first, throwsA(same(error)));
      gate.completeError(error, trace);
      await Future.wait([waiterCheck, callerCheck]);
      expect(service.initializationState, InitializationState.failed);
      expect(identical(service.init(), first), isTrue);
      await expectLater(service.ensureInit(), throwsA(same(error)));
      expect(service.calls, 1);
      service.initialize = () async {};
      final retry = service.retryInit();
      expect(identical(retry, first), isFalse);
      await retry;
      expect(service.calls, 2);
      expect(service.initializationState, InitializationState.ready);
    },
  );

  test(
    'synchronous initialization errors are delivered as future errors',
    () async {
      final error = StateError('sync failure');
      final service = _Service(() => throw error);
      await expectLater(service.init(), throwsA(same(error)));
      expect(service.initializationState, InitializationState.failed);
    },
  );
}
