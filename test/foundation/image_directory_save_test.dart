import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera_next/foundation/image_directory_save.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_saf/venera_saf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Directory destination;
  late File source;
  const saver = ImageDirectorySaver();
  const channel = MethodChannel('venera/saf');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    root = Directory.systemTemp.createTempSync('image-directory-save-');
    destination = Directory(p.join(root.path, '图片'))..createSync();
    source = File(p.join(root.path, 'source.jpg'))
      ..writeAsBytesSync([255, 216, 1, 2, 255, 217]);
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    root.deleteSync(recursive: true);
  });

  test('Unicode titles retain original chapter, page and extension', () {
    expect(imageSaveFilename('漫画_EP2_P13.jpg'), '漫画_EP2_P13.jpg');
    final title = List.filled(200, '漫😀').join();
    final result = imageSaveFilename('${title}_EP200_P12345.avif');
    expect(result, endsWith('_EP200_P12345.avif'));
    expect(utf8.encode(result).length, lessThanOrEqualTo(222));
    expect(result.runes, isNot(contains(0xfffd)));
    expect(utf8.decode(utf8.encode(result)), isNot(contains('\uFFFD')));
    expect(
      imageSaveFilename('../a\\b:bad\u0000_EP1_P2.png'),
      isNot(contains(RegExp(r'[\\/:\x00]'))),
    );
    expect(imageSaveFilename('CON.jpg'), '_CON.jpg');
  });

  test(
    'concurrent same-name saves preserve existing files and exact bytes',
    () async {
      final existing = File(p.join(destination.path, '漫画_EP2_P13.jpg'))
        ..writeAsBytesSync([9]);
      final sources = [
        for (var i = 0; i < 4; i++)
          File(p.join(root.path, '$i.jpg'))
            ..writeAsBytesSync([255, 216, i, 255, 217]),
      ];
      final paths = await Future.wait([
        for (final file in sources)
          saver.save(
            directory: destination.path,
            source: file,
            filename: '漫画_EP2_P13.jpg',
          ),
      ]);
      expect(paths.toSet(), hasLength(4));
      expect(existing.readAsBytesSync(), [9]);
      for (var i = 0; i < paths.length; i++) {
        expect(File(paths[i]).readAsBytesSync(), sources[i].readAsBytesSync());
        expect(p.basename(paths[i]), matches(r'^漫画_EP2_P13 \([1-4]\)\.jpg$'));
      }
    },
  );

  test('removed directories fail before creating an output', () async {
    destination.deleteSync();
    await expectLater(
      saver.save(
        directory: destination.path,
        source: source,
        filename: 'page.jpg',
      ),
      throwsA(isA<ImageSaveDirectoryUnavailable>()),
    );
    expect(destination.existsSync(), isFalse);
    expect(source.existsSync(), isTrue);
  });

  test(
    'cancellation after exclusive reservation removes only its new output',
    () async {
      final existing = File(p.join(destination.path, 'page.jpg'))
        ..writeAsBytesSync([8]);
      var checks = 0;
      await expectLater(
        saver.save(
          directory: destination.path,
          source: source,
          filename: 'page.jpg',
          checkStop: () {
            if (++checks == 4) throw const SelectionCancelled();
          },
        ),
        throwsA(isA<SelectionCancelled>()),
      );
      expect(destination.listSync(), hasLength(1));
      expect(existing.readAsBytesSync(), [8]);
      expect(source.existsSync(), isTrue);
    },
  );

  test('source read failure does not leave a claimed saved image', () async {
    source.deleteSync();
    await expectLater(
      saver.save(
        directory: destination.path,
        source: source,
        filename: 'page.jpg',
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(destination.listSync(), isEmpty);
  });

  test(
    'Android dispatch retains the original source and selected directory',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'saveNewFile');
        expect(call.arguments, {
          'directory': 'android://primary:Pictures/漫画',
          'source': source.path,
          'filename': '漫画_EP2_P13.jpg',
        });
        expect(source.readAsBytesSync(), [255, 216, 1, 2, 255, 217]);
        return 'android://primary:Pictures/漫画/漫画_EP2_P13 (1).jpg';
      });
      expect(
        await AndroidDirectory.fromPathSync(
          'android://primary:Pictures/漫画',
        )!.saveNewFile(source: source, filename: '漫画_EP2_P13.jpg'),
        endsWith('/漫画_EP2_P13 (1).jpg'),
      );
    },
  );
}
