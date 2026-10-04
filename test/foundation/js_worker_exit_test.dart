import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/js_pool.dart';

void _exitBeforeReady(JsWorkerStart start) => Isolate.exit();

void _failBeforeReady(JsWorkerStart start) =>
    throw StateError('startup worker failure');

void _controlledWorker(JsWorkerStart start) {
  final port = ReceivePort();
  start.replies.send(port.sendPort);
  port.listen((message) {
    if (message == 'exit') Isolate.exit();
    if (message == 'fail') throw StateError('active worker failure');
    if (message is Task && message.jsFunction == 'control') {
      start.replies.send(TaskResult(message.id, port.sendPort, null));
    }
    // Other tasks intentionally remain pending until the parent requests exit.
  });
}

void main() {
  test('exit before handshake fails waiting task and permits close', () async {
    final engine = IsolateJsEngine(Uint8List(0), entryPoint: _exitBeforeReady);
    await expectLater(
      engine.execute('wait', []).timeout(const Duration(seconds: 5)),
      throwsStateError,
    );
    await engine.close().timeout(const Duration(seconds: 5));
    expect(engine.pendingTasks, 0);
    await expectLater(engine.execute('later', []), throwsException);
  });

  test('unhandled startup error preserves remote message and stack', () async {
    final engine = IsolateJsEngine(Uint8List(0), entryPoint: _failBeforeReady);
    await expectLater(
      engine.execute('wait', []).timeout(const Duration(seconds: 5)),
      throwsA(
        isA<RemoteError>()
            .having(
              (error) => error.toString(),
              'message',
              contains('startup worker failure'),
            )
            .having(
              (error) => error.stackTrace.toString(),
              'stack',
              contains('_failBeforeReady'),
            ),
      ),
    );
    await engine.close().timeout(const Duration(seconds: 5));
  });

  for (final operation in ['exit', 'fail']) {
    test(
      'worker $operation releases active tasks while close drains',
      () async {
        final engine = IsolateJsEngine(
          Uint8List(0),
          entryPoint: _controlledWorker,
        );
        final control = await engine.execute('control', []) as SendPort;
        final first = engine.execute('wait', []);
        final second = engine.execute('wait', []);
        final matcher = operation == 'exit'
            ? isA<StateError>()
            : isA<RemoteError>().having(
                (e) => e.toString(),
                'message',
                contains('active worker failure'),
              );
        final checked = Future.wait([
          expectLater(
            first.timeout(const Duration(seconds: 5)),
            throwsA(matcher),
          ),
          expectLater(
            second.timeout(const Duration(seconds: 5)),
            throwsA(matcher),
          ),
        ]);
        await Future<void>.delayed(Duration.zero);
        expect(engine.pendingTasks, 2);
        final closing = engine.close();
        expect(engine.close(), same(closing));
        control.send(operation);
        await checked;
        await closing.timeout(const Duration(seconds: 5));
        expect(engine.pendingTasks, 0);
        await expectLater(engine.execute('later', []), throwsException);
      },
    );
  }
}
