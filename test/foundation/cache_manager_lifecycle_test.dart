import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/cache_scan.dart';

void main() {
  late Directory directory;
  late CacheManager? previous;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('cache-lifecycle-');
    previous = CacheManager.instance;
    CacheManager.instance = null;
    App.dataPath = directory.path;
    App.cachePath = directory.path;
  });
  tearDown(() async {
    await CacheManager.instance?.dispose();
    CacheManager.instance = previous;
    await directory.delete(recursive: true);
  });

  test(
    'schema failure closes its owned connection and permits repair',
    () async {
      final path = '${directory.path}/cache.db';
      sqlite3.open(path).dispose();
      late Database opened;
      expect(
        () => CacheManager.open(
          dataPath: directory.path,
          cacheRoot: directory.path,
          openDatabase: (path) =>
              opened = sqlite3.open(path, mode: OpenMode.readOnly),
        ),
        throwsA(isA<SqliteException>()),
      );
      expect(() => opened.select('SELECT 1'), throwsStateError);
      final repaired = CacheManager();
      await repaired.writeCache('repaired', [1, 2]);
      expect(await (await repaired.findCache('repaired'))!.readAsBytes(), [
        1,
        2,
      ]);
    },
  );

  test(
    'singleton stays closed to new work until accepted writes drain',
    () async {
      final gate = Completer<CacheScanResult>();
      final old = CacheManager.instance = CacheManager.open(
        dataPath: directory.path,
        cacheRoot: directory.path,
        scanner: (_, _) => gate.future,
      );
      final scanning = old.start();
      final write = old.writeCache('accepted', [3, 4]);
      final closing = old.dispose();
      expect(identical(closing, old.dispose()), isTrue);
      expect(CacheManager(), same(old));
      await expectLater(
        CacheManager().writeCache('late', [9]),
        throwsStateError,
      );
      gate.complete(const CacheScanResult(0, []));
      await Future.wait([scanning, write, closing]);
      expect(CacheManager.instance, isNull);
      final replacement = CacheManager();
      expect(replacement, isNot(same(old)));
      expect(await (await replacement.findCache('accepted'))!.readAsBytes(), [
        3,
        4,
      ]);
      await old.dispose();
      expect(CacheManager.instance, same(replacement));
    },
  );

  test('old delayed disposal cannot clear a replacement singleton', () async {
    final gate = Completer<CacheScanResult>();
    final old = CacheManager.instance = CacheManager.open(
      dataPath: directory.path,
      cacheRoot: directory.path,
      scanner: (_, _) => gate.future,
    );
    final scanning = old.start();
    final closing = old.dispose();
    final other = Directory('${directory.path}/other')..createSync();
    final replacement = CacheManager.instance = CacheManager.open(
      dataPath: other.path,
      cacheRoot: other.path,
    );
    gate.complete(const CacheScanResult(0, []));
    await Future.wait([scanning, closing]);
    expect(CacheManager.instance, same(replacement));
    await replacement.writeCache('new', [5]);
    expect(await (await replacement.findCache('new'))!.readAsBytes(), [5]);
  });
}
