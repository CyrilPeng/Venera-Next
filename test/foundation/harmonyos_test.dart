import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera_next/foundation/file_selection.dart';
import 'package:venera_next/foundation/harmonyos.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const token = '12345678-1234-4234-8234-123456789abc';
  late Directory root;
  late String cache;
  final calls = <MethodCall>[];

  setUp(() {
    root = Directory.systemTemp.createTempSync('venera-harmonyos-');
    cache = p.join(root.path, 'cache');
    calls.clear();
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(HarmonyOS.channel, null);
    await root.delete(recursive: true);
  });

  void mock(Future<Object?> Function(MethodCall) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(HarmonyOS.channel, (call) async {
          calls.add(call);
          return handler(call);
        });
  }

  Map<String, String> receipt({String name = 'Book.cbz'}) => {
    'path': p.join(cache, 'selected_files', token, name),
    'name': name,
    'token': token,
  };

  test('sandbox directories must be local absolute paths', () async {
    mock((_) async => {'data': p.join(root.path, 'data'), 'cache': cache});
    final directories = await HarmonyOS.directories();
    expect(await Directory(directories.data).exists(), isTrue);
    expect(await Directory(directories.cache).exists(), isTrue);
    for (final path in ['relative', 'file://private/data', '']) {
      mock((_) async => {'data': path, 'cache': cache});
      await expectLater(HarmonyOS.directories(), throwsStateError);
    }
  });

  test(
    'picker cancellation does not invent a file or trigger cleanup',
    () async {
      mock((_) async => []);
      expect(
        await HarmonyOS.selectFiles(extensions: ['cbz'], cachePath: cache),
        isEmpty,
      );
      expect(calls.map((call) => call.method), ['selectFiles']);
    },
  );

  test('selected URI copy remains owned until all consumers settle', () async {
    final selected = receipt();
    final file = File(selected['path']!)..createSync(recursive: true);
    file.writeAsStringSync('real content');
    mock((call) async {
      if (call.method == 'selectFiles') return [selected];
      if (call.method == 'releaseFile') await file.delete();
      return null;
    });
    final files = await HarmonyOS.selectFiles(
      extensions: ['cbz'],
      cachePath: cache,
    );
    final entered = Completer<void>();
    final finish = Completer<void>();
    final reading = files.single.withFile((actual) async {
      expect(actual.path, file.path);
      entered.complete();
      await finish.future;
      return actual.readAsString();
    });
    await entered.future;
    final closing = files.single.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(file.existsSync(), isTrue);
    expect(calls.where((call) => call.method == 'releaseFile'), isEmpty);
    finish.complete();
    expect(await reading, 'real content');
    await closing;
    expect(file.existsSync(), isFalse);
    await files.single.dispose();
    expect(calls.where((call) => call.method == 'releaseFile'), hasLength(1));
  });

  test('cleanup failure retains the same receipt for explicit retry', () async {
    final file = File(p.join(root.path, 'copy'))..writeAsStringSync('keep');
    var releases = 0;
    final selected = FileSelection.ownedCopy(
      path: file.path,
      name: 'copy',
      token: token,
      release: (actual) async {
        expect(actual, {'path': file.path, 'token': token});
        if (++releases == 1) throw StateError('cleanup failed');
        await file.delete();
      },
    );
    await expectLater(selected.dispose(), throwsStateError);
    expect(file.existsSync(), isTrue);
    await selected.dispose();
    expect(releases, 2);
    expect(file.existsSync(), isFalse);
  });

  test(
    'invalid extensions release owned copies without consuming them',
    () async {
      final selected = receipt(name: 'secret.txt');
      mock((call) async => call.method == 'selectFiles' ? [selected] : null);
      await expectLater(
        HarmonyOS.selectFiles(extensions: ['cbz'], cachePath: cache),
        throwsFormatException,
      );
      expect(calls.last.method, 'releaseFile');
      expect(calls.last.arguments, {'path': selected['path'], 'token': token});
    },
  );

  test('untrusted sibling paths and URI receipts are never released', () async {
    for (final path in [
      p.join('$cache-extra', 'file.cbz'),
      'file://private/file.cbz',
    ]) {
      mock(
        (_) async => [
          {...receipt(), 'path': path},
        ],
      );
      await expectLater(
        HarmonyOS.selectFiles(extensions: ['cbz'], cachePath: cache),
        throwsStateError,
      );
      expect(calls.where((call) => call.method == 'releaseFile'), isEmpty);
      calls.clear();
    }
  });

  test(
    'save cancellation and platform errors are not reported as success',
    () async {
      final source = File(p.join(root.path, 'Book.cbz'))
        ..writeAsStringSync('source');
      mock((_) async => false);
      expect(await HarmonyOS.saveFile(source), isFalse);
      expect(source.readAsStringSync(), 'source');
      mock((_) async => throw PlatformException(code: 'write_failed'));
      await expectLater(
        HarmonyOS.saveFile(source),
        throwsA(isA<PlatformException>()),
      );
      expect(source.readAsStringSync(), 'source');
    },
  );
}
