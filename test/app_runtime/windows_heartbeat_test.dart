import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/windows_heartbeat.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('venera/method_channel');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'concurrent beats share registration and stop follows every reply',
    () async {
      final calls = <MethodCall>[];
      final gates = [Completer<void>(), Completer<void>()];
      var beats = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'startHeartbeat') return 42;
        if (call.method == 'heartBeat') await gates[beats++].future;
        return null;
      });
      final heartbeat = WindowsHeartbeat();
      final first = heartbeat.send();
      final second = heartbeat.send();
      await pumpEventQueue();
      expect(calls.map((call) => call.method), [
        'startHeartbeat',
        'heartBeat',
        'heartBeat',
      ]);
      var closed = false;
      final closing = heartbeat.close();
      unawaited(closing.then((_) => closed = true));
      expect(identical(closing, heartbeat.close()), isTrue);
      gates.last.complete();
      await second;
      await pumpEventQueue();
      expect(closed, isFalse);
      expect(calls, hasLength(3));
      gates.first.complete();
      await first;
      await closing;
      expect(calls.last.method, 'stopHeartbeat');
      expect(calls.skip(1).map((call) => call.arguments), [42, 42, 42]);
    },
  );

  test(
    'close during registration waits for ownership and suppresses beat',
    () async {
      final registration = Completer<int>();
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'startHeartbeat'
            ? await registration.future
            : null;
      });
      final heartbeat = WindowsHeartbeat();
      final sending = heartbeat.send();
      await pumpEventQueue();
      final closing = heartbeat.close();
      var closed = false;
      unawaited(closing.then((_) => closed = true));
      await pumpEventQueue();
      expect(closed, isFalse);
      registration.complete(7);
      await sending;
      await closing;
      expect(calls.map((call) => call.method), [
        'startHeartbeat',
        'stopHeartbeat',
      ]);
      expect(calls.last.arguments, 7);
    },
  );

  test(
    'late registration and old close keep the replacement owner intact',
    () async {
      final oldRegistration = Completer<int>();
      var registrations = 0;
      var nativeOwner = 0;
      final stops = <Object?>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'startHeartbeat') {
          nativeOwner = ++registrations;
          return registrations == 1
              ? await oldRegistration.future
              : nativeOwner;
        }
        if (call.method == 'stopHeartbeat') {
          stops.add(call.arguments);
          if (call.arguments == nativeOwner) nativeOwner = 0;
        }
        return null;
      });
      final old = WindowsHeartbeat();
      final replacement = WindowsHeartbeat();
      final sending = old.send();
      await pumpEventQueue();
      final closing = old.close();
      await replacement.send();
      expect(nativeOwner, 2);
      oldRegistration.complete(1);
      await sending;
      await closing;
      expect(stops, [1]);
      expect(nativeOwner, 2);
      await replacement.close();
      expect(stops, [1, 2]);
      expect(nativeOwner, 0);
    },
  );

  test('registration failure permits the next tick to retry', () async {
    var starts = 0;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'startHeartbeat') {
        if (++starts == 1) {
          throw PlatformException(code: 'temporarily unavailable');
        }
        return 8;
      }
      return null;
    });
    final heartbeat = WindowsHeartbeat();
    await expectLater(heartbeat.send(), throwsA(isA<PlatformException>()));
    await heartbeat.send();
    await heartbeat.close();
    expect(calls.map((call) => call.method), [
      'startHeartbeat',
      'startHeartbeat',
      'heartBeat',
      'stopHeartbeat',
    ]);
  });

  test(
    'invalid registration is reported without sending an unowned beat',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return null;
      });
      final heartbeat = WindowsHeartbeat();
      await expectLater(heartbeat.send(), throwsStateError);
      await heartbeat.close();
      expect(calls, ['startHeartbeat']);
    },
  );

  test(
    'failed stop stays observable and does not issue duplicate stops',
    () async {
      var stops = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'startHeartbeat') return 1;
        if (call.method == 'stopHeartbeat') {
          stops++;
          throw PlatformException(code: 'stop failed');
        }
        return null;
      });
      final heartbeat = WindowsHeartbeat();
      await heartbeat.send();
      final closing = heartbeat.close();
      await expectLater(closing, throwsA(isA<PlatformException>()));
      expect(identical(closing, heartbeat.close()), isTrue);
      expect(stops, 1);
      await expectLater(heartbeat.send(), throwsStateError);
    },
  );

  test('closing an unused mount never starts a native monitor', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      fail('Unexpected ${call.method}');
    });
    final heartbeat = WindowsHeartbeat();
    await heartbeat.close();
    await expectLater(heartbeat.send(), throwsStateError);
  });
}
