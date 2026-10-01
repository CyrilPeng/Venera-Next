import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/local_comics/download_task_store.dart';

void main() {
  late Directory root;
  late DownloadTaskStore store;
  late List<Object> errors;
  setUp(() {
    root = Directory.systemTemp.createTempSync('download-task-store-');
    errors = [];
    store = DownloadTaskStore(onError: (error, stack) => errors.add(error));
  });
  tearDown(() async {
    await store.pendingWrites;
    root.deleteSync(recursive: true);
  });

  test(
    'queued snapshots freeze nested values and destination before writes',
    () async {
      final firstPath = '${root.path}/first.json';
      final secondPath = '${root.path}/second.json';
      final chapters = ['a'];
      final tasks = [
        {'id': 'one', 'chapters': chapters},
      ];
      final first = store.save(firstPath, tasks);
      chapters.add('b');
      final second = store.save(secondPath, tasks);
      tasks.clear();
      await Future.wait([first, second]);
      expect(
        jsonDecode(File(firstPath).readAsStringSync()).single['chapters'],
        ['a'],
      );
      expect(
        jsonDecode(File(secondPath).readAsStringSync()).single['chapters'],
        ['a', 'b'],
      );
      await store.save(firstPath, []);
      expect(jsonDecode(File(firstPath).readAsStringSync()), isEmpty);
      expect(root.listSync().whereType<Directory>(), isEmpty);
      expect(errors, isEmpty);
    },
  );

  test(
    'failed replacement preserves destination and next save can retry',
    () async {
      final path = '${root.path}/tasks.json';
      final target = Directory(path)..createSync();
      final sentinel = File('$path/preserved')..writeAsStringSync('keep');
      await expectLater(
        store.save(path, [
          {'id': 'one'},
        ]),
        throwsA(isA<FileSystemException>()),
      );
      await store.pendingWrites;
      expect(errors, hasLength(1));
      expect(sentinel.readAsStringSync(), 'keep');
      final remaining = root.listSync().whereType<Directory>().toList();
      expect(remaining, hasLength(1));
      expect(
        FileSystemEntity.identicalSync(remaining.single.path, path),
        isTrue,
      );
      target.deleteSync(recursive: true);
      await store.save(path, [
        {'id': 'retry'},
      ]);
      expect(jsonDecode(File(path).readAsStringSync()).single['id'], 'retry');
      expect(root.listSync().whereType<Directory>(), isEmpty);
    },
  );

  test(
    'serialization failure leaves last snapshot intact and queue usable',
    () async {
      final path = '${root.path}/tasks.json';
      await store.save(path, [
        {'id': 'saved'},
      ]);
      final before = File(path).readAsStringSync();
      expect(
        () => store.save(path, [
          {'bad': Object()},
        ]),
        throwsA(isA<JsonUnsupportedObjectError>()),
      );
      expect(File(path).readAsStringSync(), before);
      await store.save(path, []);
      expect(File(path).readAsStringSync(), '[]');
    },
  );

  test(
    'restore is all-or-nothing, preserves invalid input and skips unsupported tasks',
    () {
      final path = '${root.path}/tasks.json';
      final file = File(path);
      String? decode(Map<String, dynamic> row) => row['id'] as String?;
      expect(store.restore(path, decode), isNull);
      for (final invalid in [
        '{',
        '{}',
        '[{"id":"valid"},1]',
        '[{"id":"valid"},{"id":9}]',
      ]) {
        file.writeAsStringSync(invalid);
        expect(() => store.restore(path, decode), throwsA(anything));
        expect(file.readAsStringSync(), invalid);
      }
      file.writeAsStringSync(
        '[{"id":"one"},{"unsupported":true},{"id":"two"}]',
      );
      expect(store.restore(path, decode), ['one', 'two']);
      expect(store.restore(path, decode), ['one', 'two']);
    },
  );
}
