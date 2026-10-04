import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/js_pool.dart';

void _cleanupWorker(JsWorkerStart start) {
  final port = ReceivePort();
  SendPort? observer;
  String mode = '';
  start.replies.send(port.sendPort);
  port.listen((message) {
    if (message is Task) {
      observer = message.args.single as SendPort;
      mode = message.jsFunction;
      start.replies.send(TaskResult(message.id, port.sendPort, null));
    } else if (message is JsWorkerStop) {
      if (mode == 'missing') Isolate.exit();
      observer!.send('cleaning');
    } else if (message == 'ack') {
      start.replies.send(
        JsWorkerStopped(mode == 'failure' ? 'cleanup failed' : null),
      );
      observer!.send('acknowledged');
    } else if (message == 'exit') {
      port.close();
    }
  });
}

void main() {
  for (final mode in ['success', 'failure']) {
    test('close waits for cleanup acknowledgment and exit: $mode', () async {
      final events = ReceivePort();
      final iterator = StreamIterator<dynamic>(events);
      final engine = IsolateJsEngine(Uint8List(0), entryPoint: _cleanupWorker);
      final control = await engine.execute(mode, [events.sendPort]) as SendPort;
      var completed = false;
      final closing = engine.close();
      final checked = mode == 'success'
          ? expectLater(closing, completes)
          : expectLater(
              closing,
              throwsA(
                isA<StateError>().having(
                  (error) => error.message,
                  'message',
                  'cleanup failed',
                ),
              ),
            );
      final observed = checked.then((_) => completed = true);
      try {
        expect(engine.close(), same(closing));
        expect(
          await iterator.moveNext().timeout(const Duration(seconds: 5)),
          isTrue,
        );
        expect(iterator.current, 'cleaning');
        expect(completed, isFalse);
        control.send('ack');
        expect(
          await iterator.moveNext().timeout(const Duration(seconds: 5)),
          isTrue,
        );
        expect(iterator.current, 'acknowledged');
        await pumpEventQueue();
        expect(completed, isFalse);
        control.send('exit');
        await observed.timeout(const Duration(seconds: 5));
        await expectLater(engine.execute('later', []), throwsException);
      } finally {
        control.send('exit');
        await iterator.cancel();
        events.close();
      }
    });
  }

  test(
    'exit without acknowledgment does not claim cleanup succeeded',
    () async {
      final events = ReceivePort();
      addTearDown(events.close);
      final engine = IsolateJsEngine(Uint8List(0), entryPoint: _cleanupWorker);
      await engine.execute('missing', [events.sendPort]);
      await expectLater(
        engine.close().timeout(const Duration(seconds: 5)),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('without confirming'),
          ),
        ),
      );
    },
  );
}
