import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as path;
import 'package:venera_native/venera_native.dart';
import 'package:venera_next/foundation/image_processing.dart' as processing;

const fixtures = 'packages/venera_native/test/fixtures';
final nativeHost = Platform.isWindows || Platform.isLinux;

void deleteOwnedTemp(Directory directory) {
  final target = directory.resolveSymbolicLinksSync();
  final temporaryRoot = Directory.systemTemp.resolveSymbolicLinksSync();
  if (!path.isWithin(temporaryRoot, target) ||
      !path.basename(target).startsWith('venera-native-')) {
    throw StateError('Refusing to remove an unowned temporary directory');
  }
  directory.deleteSync(recursive: true);
}

void main() {
  setUpAll(() {
    if (Platform.isWindows) {
      final library =
          Platform.environment['VENERA_NATIVE_TEST_LIBRARY'] ??
          Directory(
            'build/windows/x64/runner/Debug/venera_native.dll',
          ).absolute.path;
      DynamicLibrary.open(library);
    }
  });

  test(
    'PNG preserves all RGBA channels, alpha and typed-view offsets',
    () {
      final expected = Uint8List.fromList([
        255,
        0,
        0,
        255,
        0,
        20,
        255,
        128,
        10,
        200,
        30,
        1,
        3,
        4,
        5,
        0,
      ]);
      final backing = Uint8List(24)..setRange(4, 20, expected);
      final encoded = encodePngRgba(
        Uint8List.sublistView(backing, 4, 20),
        2,
        2,
      );
      backing.fillRange(0, backing.length, 0);
      for (var repeat = 0; repeat < 10; repeat++) {
        encodePngRgba(Uint8List(4), 1, 1);
      }
      final decoded = image.decodePng(encoded)!;
      expect((decoded.width, decoded.height), (2, 2));
      for (var index = 0; index < 4; index++) {
        final pixel = decoded.getPixel(index % 2, index ~/ 2);
        expect([
          pixel.r,
          pixel.g,
          pixel.b,
          pixel.a,
        ], expected.sublist(index * 4, index * 4 + 4));
      }
    },
    skip: !nativeHost,
  );

  test('application Image encodes only its Uint32 view', () {
    final backing = Uint32List.fromList([
      0xffffffff,
      0xff0000ff,
      0x80ff1400,
      0,
    ]);
    final encoded = processing.Image(
      Uint32List.sublistView(backing, 1, 3),
      2,
      1,
    ).encodePng();
    final decoded = image.decodePng(encoded)!;
    expect(decoded.getPixel(0, 0).r, 255);
    expect(decoded.getPixel(1, 0).b, 255);
    expect(decoded.getPixel(1, 0).a, 128);
  }, skip: !nativeHost);

  test('invalid PNG input fails before another valid encoding', () {
    for (final dimensions in [
      (0, 1),
      (-1, 2),
      (1, 0),
      (0x100000000, 1),
      (0x80000000, 0x80000000),
      (2, 1),
    ]) {
      expect(
        () => encodePngRgba(Uint8List(4), dimensions.$1, dimensions.$2),
        throwsArgumentError,
      );
    }
    expect(image.decodePng(encodePngRgba(Uint8List(4), 1, 1)), isNotNull);
  }, skip: !nativeHost);

  for (final kind in ['solid', 'non-solid']) {
    test(
      'real $kind 7z preserves Unicode, every byte and empty files',
      () async {
        final output = Directory.systemTemp.createTempSync(
          'venera-native-$kind-',
        );
        try {
          await extractSevenZip('$fixtures/$kind.7z', output.path);
          final expected =
              jsonDecode(File('$fixtures/expected.json').readAsStringSync())
                  as Map;
          for (final entry in expected.entries) {
            final file = File(
              path.joinAll([output.path, ...entry.key.toString().split('/')]),
            );
            expect(file.existsSync(), isTrue, reason: entry.key.toString());
            final hex = entry.value as String;
            final bytes = [
              for (var offset = 0; offset < hex.length; offset += 2)
                int.parse(hex.substring(offset, offset + 2), radix: 16),
            ];
            expect(file.readAsBytesSync(), bytes, reason: entry.key.toString());
          }
          expect(
            output.listSync(recursive: true).whereType<File>().length,
            expected.length,
          );
        } finally {
          deleteOwnedTemp(output);
        }
      },
      skip: !nativeHost,
    );
  }

  for (final failure in [
    'traversal',
    'absolute',
    'drive',
    'duplicate',
    'file-parent',
    'symlink',
    'bad-crc',
    'truncated',
    'encrypted',
    'missing-name',
  ]) {
    test('rejects $failure 7z before writing any payload', () async {
      final workspace = Directory.systemTemp.createTempSync(
        'venera-native-reject-',
      );
      final output = Directory(path.join(workspace.path, 'output'))
        ..createSync();
      final sentinel = File(path.join(workspace.path, 'escape.bin'))
        ..writeAsStringSync('keep');
      try {
        await expectLater(
          extractSevenZip('$fixtures/$failure.7z', output.path),
          throwsA(anything),
        );
        expect(output.listSync(recursive: true), isEmpty);
        expect(sentinel.readAsStringSync(), 'keep');
      } finally {
        deleteOwnedTemp(workspace);
      }
    }, skip: !nativeHost);
  }

  test(
    '7z archive and output paths retain Unicode on the native bridge',
    () async {
      final workspace = Directory.systemTemp.createTempSync(
        'venera-native-unicode-',
      );
      try {
        final archive = File(path.join(workspace.path, '漫画 🌈.cb7'));
        File('$fixtures/copy.7z').copySync(archive.path);
        final output = path.join(workspace.path, '解压结果');
        await extractSevenZip(archive.path, output);
        expect(
          File(path.join(output, 'safe/page.bin')).readAsStringSync(),
          'verified-data',
        );
      } finally {
        deleteOwnedTemp(workspace);
      }
    },
    skip: !nativeHost,
  );

  test(
    'failed opens and reads release resources before a concurrent retry',
    () async {
      final workspace = Directory.systemTemp.createTempSync(
        'venera-native-retry-',
      );
      try {
        for (var iteration = 0; iteration < 15; iteration++) {
          await expectLater(
            extractSevenZip(
              '$fixtures/missing.7z',
              path.join(workspace.path, 'missing'),
            ),
            throwsA(anything),
          );
          await expectLater(
            extractSevenZip(
              '$fixtures/bad-crc.7z',
              path.join(workspace.path, 'failed'),
            ),
            throwsA(anything),
          );
        }
        await Future.wait([
          for (var index = 0; index < 8; index++)
            extractSevenZip(
              '$fixtures/copy.7z',
              path.join(workspace.path, '$index'),
            ),
        ]);
        for (var index = 0; index < 8; index++) {
          expect(
            File(
              path.join(workspace.path, '$index/safe/page.bin'),
            ).readAsStringSync(),
            'verified-data',
          );
        }
      } finally {
        deleteOwnedTemp(workspace);
      }
    },
    skip: !nativeHost,
  );

  test(
    'existing output link cannot redirect an archive write',
    () async {
      final workspace = Directory.systemTemp.createTempSync(
        'venera-native-link-',
      );
      final output = Directory(path.join(workspace.path, 'output'))
        ..createSync();
      final outside = Directory(path.join(workspace.path, 'outside'))
        ..createSync();
      try {
        Link(path.join(output.path, 'safe')).createSync(outside.path);
        await expectLater(
          extractSevenZip('$fixtures/copy.7z', output.path),
          throwsA(anything),
        );
        expect(outside.listSync(), isEmpty);
      } finally {
        deleteOwnedTemp(workspace);
      }
    },
    skip: !Platform.isLinux,
  );
}
