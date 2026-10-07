import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/volume.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('venera/volume');
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<void> event(String token, int value) async {
    final reply = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(
        MethodCall('event', {'token': token, 'value': value}),
      ),
      (_) => reply.complete(),
    );
    await reply.future;
  }

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'native acknowledgement gates close through late activation and cancellation',
    () async {
      final activation = Completer<void>();
      final cancellation = Completer<void>();
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        await (call.method == 'listen'
            ? activation.future
            : cancellation.future);
        return null;
      });
      final events = <Object?>[];
      final lease = connectReaderVolume(events.add);
      final token = (calls.single.arguments as Map)['token'] as String;
      var closed = false;
      final closing = lease.closeAndWait();
      expect(identical(closing, lease.closeAndWait()), isTrue);
      unawaited(closing.then((_) => closed = true));
      await event(token, 2);
      expect(events, isEmpty);
      expect(calls.map((c) => c.method), ['listen']);
      activation.complete();
      await lease.ready;
      await Future<void>.delayed(Duration.zero);
      expect(calls.map((c) => c.method), ['listen', 'cancel']);
      expect(closed, isFalse);
      expect((calls.last.arguments as Map)['token'], token);
      cancellation.complete();
      await closing;
      await lease.closeAndWait();
      expect(calls, hasLength(2));
    },
  );

  test(
    'independent tokens survive late old cancellation and discard retired events',
    () async {
      final oldCancellation = Completer<void>();
      final calls = <MethodCall>[];
      String? oldToken;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'cancel' &&
            (call.arguments as Map)['token'] == oldToken) {
          await oldCancellation.future;
        }
        return null;
      });
      final oldEvents = <Object?>[];
      final newEvents = <Object?>[];
      final old = connectReaderVolume(oldEvents.add);
      await old.ready;
      oldToken = (calls.last.arguments as Map)['token'] as String;
      final current = connectReaderVolume(newEvents.add);
      await current.ready;
      final currentToken = (calls.last.arguments as Map)['token'] as String;
      expect(currentToken, isNot(oldToken));
      final closing = old.closeAndWait();
      await event(oldToken, 1);
      await event(currentToken, 2);
      expect(oldEvents, isEmpty);
      expect(newEvents, [2]);
      oldCancellation.complete();
      await closing;
      await event(currentToken, 1);
      await event(oldToken, 2);
      expect(newEvents, [2, 1]);
      await current.closeAndWait();
    },
  );

  test(
    'failed cancel remains observable and retries the same token without listen',
    () async {
      final calls = <MethodCall>[];
      var failCancel = true;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'cancel' && failCancel) {
          throw PlatformException(code: 'cancel_failed');
        }
        return null;
      });
      final events = <Object?>[];
      final lease = connectReaderVolume(events.add);
      await lease.ready;
      final token = (calls.single.arguments as Map)['token'] as String;
      await expectLater(
        lease.closeAndWait(),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'cancel_failed',
          ),
        ),
      );
      await event(token, 2);
      expect(events, isEmpty);
      failCancel = false;
      await lease.closeAndWait();
      expect(calls.map((c) => c.method), ['listen', 'cancel', 'cancel']);
      expect(calls.map((c) => (c.arguments as Map)['token']).toSet(), {token});
    },
  );

  test(
    'failed listen still cancels native token and successful release is final',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'listen') {
          throw PlatformException(code: 'listen_failed');
        }
        return null;
      });
      final lease = connectReaderVolume((_) {});
      await expectLater(lease.ready, throwsA(isA<PlatformException>()));
      await lease.closeAndWait();
      await lease.closeAndWait();
      expect(calls.map((c) => c.method), ['listen', 'cancel']);
      expect(calls.first.arguments, calls.last.arguments);
    },
  );
}
