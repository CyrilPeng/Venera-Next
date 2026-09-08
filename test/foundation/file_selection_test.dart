import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/file_interaction.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('venera/select_file');

  setUp(() {
    App.cachePath = FilePath.join(
      Directory.systemTemp.path,
      'venera-selection-test-cache',
    );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
  });

  test(
    'releasing a desktop selection leaves the original file intact',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'venera-selection-source-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final source = File(FilePath.join(directory.path, 'Book.pdf'))
        ..writeAsBytesSync([1, 2, 3]);
      final selection = FileSelection(source.path);
      expect((await selection.prepare()).path, source.path);
      await selection.dispose();
      expect(source.readAsBytesSync(), [1, 2, 3]);
    },
  );

  test(
    'Android selections are prepared lazily and release their own temporary file once',
    () async {
      final calls = <MethodCall>[];
      final selectedPath = FilePath.join(
        App.cachePath,
        'selected_files',
        'unique',
        'Book.pdf',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'prepareFile') {
              return {'path': selectedPath, 'temporary': true};
            }
            return null;
          });
      final selection = FileSelection.androidDocument(
        uri: 'content://books/1',
        name: 'Book.pdf',
      );
      expect(calls, isEmpty);
      expect(selection.name, 'Book.pdf');

      expect((await selection.prepare()).path, selectedPath);
      expect((await selection.prepare()).path, selectedPath);
      expect(calls.map((call) => call.method), ['prepareFile']);
      expect(calls.single.arguments, 'content://books/1');

      await selection.dispose();
      await selection.dispose();
      expect(calls.map((call) => call.method), ['prepareFile', 'releaseFile']);
      expect(calls.last.arguments, selectedPath);
      await expectLater(selection.prepare(), throwsStateError);
    },
  );

  test('direct source files are never sent to temporary cleanup', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return {
            'path': FilePath.join(Directory.systemTemp.path, 'Book.pdf'),
            'temporary': false,
          };
        });
    final selection = FileSelection.androidDocument(
      uri: 'content://books/1',
      name: 'Book.pdf',
    );
    await selection.prepare();
    await selection.dispose();
    expect(calls, ['prepareFile']);
  });

  test(
    'unprepared and failed selections do not release unrelated paths',
    () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            throw PlatformException(code: 'prepare_error');
          });
      final unopened = FileSelection.androidDocument(
        uri: 'content://books/1',
        name: 'One.pdf',
      );
      await unopened.dispose();
      expect(calls, isEmpty);

      final broken = FileSelection.androidDocument(
        uri: 'content://books/2',
        name: 'Two.pdf',
      );
      await expectLater(broken.prepare(), throwsA(isA<PlatformException>()));
      await broken.dispose();
      expect(calls, ['prepareFile']);
    },
  );
}
