import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/volume.dart';
import 'package:venera_next/features/reader/volume_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'adapter retains the Android channel and listen/cancel protocol',
    () async {
      const channel = MethodChannel('venera/volume');
      final calls = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return null;
      });
      final reader = ReaderVolumeController(
        events: readerVolumeEvents,
        nextPage: () => true,
        previousPage: () => true,
        nextChapter: () {},
        previousChapter: () {},
        onError: (error, stack) => fail('$error'),
      );
      addTearDown(() async {
        await reader.dispose();
        messenger.setMockMethodCallHandler(channel, null);
      });
      await reader.setEnabled(true);
      await reader.setEnabled(true);
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['listen']);
      await reader.setEnabled(false);
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['listen', 'cancel']);
      await reader.setEnabled(true);
      await Future<void>.delayed(Duration.zero);
      await reader.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['listen', 'cancel', 'listen', 'cancel']);
    },
  );
}
