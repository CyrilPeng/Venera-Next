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
    HarmonyOS.debugIsCurrent = null;
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

  Map<String, String> directoryReceipt({String name = 'Book'}) => {
    'path': p.join(cache, 'selected_directories', token, 'contents', name),
    'name': name,
    'token': token,
  };

  test(
    'directory cancellation and unavailable capability do not create copies',
    () async {
      mock((_) async => null);
      expect(await HarmonyOS.selectDirectory(cachePath: cache), isNull);
      mock(
        (_) async =>
            throw PlatformException(code: 'directory_selection_unavailable'),
      );
      await expectLater(
        HarmonyOS.selectDirectory(cachePath: cache),
        throwsA(isA<PlatformException>()),
      );
      expect(calls.every((call) => call.method == 'selectDirectory'), isTrue);
    },
  );

  test(
    'directory receipt is owned before copying and cannot be retained',
    () async {
      final selected = directoryReceipt();
      final copied = Directory(selected['path']!);
      final entered = Completer<void>();
      final finish = Completer<void>();
      mock((call) async {
        if (call.method == 'selectDirectory') return selected;
        expect(call.arguments, {'path': selected['path'], 'token': token});
        if (call.method == 'prepareDirectory') {
          await copied.create(recursive: true);
          File(p.join(copied.path, '1.png')).writeAsStringSync('page');
        }
        if (call.method == 'releaseDirectory') {
          await copied.parent.parent.delete(recursive: true);
        }
        return null;
      });
      final selection = (await HarmonyOS.selectDirectory(cachePath: cache))!;
      expect(calls.map((call) => call.method), ['selectDirectory']);
      await expectLater(selection.retainAccessForSession(), throwsStateError);
      final reading = selection.withDirectory((dir) async {
        entered.complete();
        await finish.future;
        expect(File(p.join(dir.path, '1.png')).readAsStringSync(), 'page');
      });
      await entered.future;
      final closing = selection.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(copied.existsSync(), isTrue);
      finish.complete();
      await reading;
      await closing;
      await selection.dispose();
      expect(calls.map((call) => call.method), [
        'selectDirectory',
        'prepareDirectory',
        'releaseDirectory',
      ]);
      expect(copied.existsSync(), isFalse);
    },
  );

  test(
    'failed directory preparation still releases exactly its owned receipt',
    () async {
      final selected = directoryReceipt();
      var releases = 0;
      mock((call) async {
        if (call.method == 'selectDirectory') return selected;
        if (call.method == 'prepareDirectory') {
          throw PlatformException(code: 'copy_failed');
        }
        if (call.method == 'releaseDirectory' && ++releases == 1) {
          throw PlatformException(code: 'busy');
        }
        return null;
      });
      final selection = (await HarmonyOS.selectDirectory(cachePath: cache))!;
      await expectLater(
        selection.withDirectory((_) async => fail('must not consume')),
        throwsA(isA<PlatformException>()),
      );
      await expectLater(selection.dispose(), throwsA(isA<PlatformException>()));
      await selection.dispose();
      expect(releases, 2);
      expect(
        calls.where((call) => call.method == 'prepareDirectory'),
        hasLength(1),
      );
    },
  );

  test('unconsumed selection closes without beginning a copy', () async {
    mock(
      (call) async =>
          call.method == 'selectDirectory' ? directoryReceipt() : null,
    );
    final selection = (await HarmonyOS.selectDirectory(cachePath: cache))!;
    await selection.dispose();
    expect(calls.map((call) => call.method), [
      'selectDirectory',
      'releaseDirectory',
    ]);
  });

  test(
    'untrusted directory receipts are never consumed or recursively released',
    () async {
      for (final selected in [
        {...directoryReceipt(), 'path': p.join('$cache-other', 'Book')},
        {...directoryReceipt(), 'path': 'file://docs/Book'},
        directoryReceipt(name: '..'),
        directoryReceipt(name: '../Book'),
        directoryReceipt(name: r'..\Book'),
        {...directoryReceipt(), 'token': 'untrusted'},
      ]) {
        calls.clear();
        mock((_) async => selected);
        await expectLater(
          HarmonyOS.selectDirectory(cachePath: cache),
          throwsStateError,
        );
        expect(calls.map((call) => call.method), ['selectDirectory']);
      }
    },
  );

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

  test(
    'screen awake uses a named field understood by the native bridge',
    () async {
      mock((_) async => null);
      await HarmonyOS.setScreenAwake(true);
      await HarmonyOS.setScreenAwake(false);
      expect(calls.map((call) => call.method), [
        'setScreenAwake',
        'setScreenAwake',
      ]);
      expect(calls.map((call) => call.arguments), [
        {'awake': true},
        {'awake': false},
      ]);
      mock((_) async => throw PlatformException(code: 'window_unavailable'));
      await expectLater(
        HarmonyOS.setScreenAwake(true),
        throwsA(isA<PlatformException>()),
      );
    },
  );
}
