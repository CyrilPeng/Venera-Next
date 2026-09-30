import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/cache_scan.dart';

({CacheManager manager, Directory root}) fixture({
  CacheScanner scanner = scanCacheDirectory,
}) {
  final root = Directory.systemTemp.createTempSync('venera-cache-');
  final manager = CacheManager.open(
    dataPath: root.path,
    cacheRoot: root.path,
    scanner: scanner,
  );
  addTearDown(() async {
    await manager.dispose();
    await root.delete(recursive: true);
  });
  return (manager: manager, root: root);
}

void main() {
  test('construction does not scan and start shares one scan', () async {
    var scans = 0;
    final gate = Completer<CacheScanResult>();
    final f = fixture(
      scanner: (_, _) {
        scans++;
        return gate.future;
      },
    );
    expect(scans, 0);
    final first = f.manager.start();
    expect(identical(first, f.manager.start()), isTrue);
    await pumpEventQueue();
    expect(scans, 1);
    gate.complete(const CacheScanResult(0, []));
    await first;
  });

  test('scan failure keeps later writes usable', () async {
    final f = fixture(scanner: (_, _) async => throw StateError('scan failed'));
    await f.manager.start();
    await f.manager.writeCache('key', [1, 2, 3]);
    expect(f.manager.currentSize, 3);
    expect(await (await f.manager.findCache('key'))!.readAsBytes(), [1, 2, 3]);
  });

  test(
    'queued clear follows scan and write without restoring stale size',
    () async {
      final gate = Completer<CacheScanResult>();
      final f = fixture(scanner: (_, _) => gate.future);
      final scanning = f.manager.start();
      final bytes = [1, 2, 3];
      final write = f.manager.writeCache('key', bytes);
      bytes[0] = 9;
      final clear = f.manager.clear();
      gate.complete(const CacheScanResult(0, []));
      await Future.wait([scanning, write, clear]);
      expect(f.manager.currentSize, 0);
      expect(await f.manager.findCache('key'), isNull);
    },
  );

  test('dispose drains accepted writes and rejects new work', () async {
    final gate = Completer<CacheScanResult>();
    final f = fixture(scanner: (_, _) => gate.future);
    final scanning = f.manager.start();
    final write = f.manager.writeCache('key', [1, 2]);
    final closing = f.manager.dispose();
    expect(identical(closing, f.manager.dispose()), isTrue);
    await expectLater(f.manager.writeCache('late', [3]), throwsStateError);
    gate.complete(const CacheScanResult(0, []));
    await Future.wait([scanning, write, closing]);
    final reopened = CacheManager.open(
      dataPath: f.root.path,
      cacheRoot: f.root.path,
    );
    try {
      await reopened.start();
      expect(await (await reopened.findCache('key'))!.readAsBytes(), [1, 2]);
      expect(reopened.currentSize, 2);
    } finally {
      await reopened.dispose();
    }
  });

  test('failed file write does not poison queued operations', () async {
    final f = fixture();
    final cache = Directory('${f.root.path}/cache');
    await cache.delete();
    final obstruction = File(cache.path)..writeAsStringSync('blocked');
    await expectLater(
      f.manager.writeCache('key', [1]),
      throwsA(isA<FileSystemException>()),
    );
    await obstruction.delete();
    await cache.create();
    await f.manager.writeCache('key', [1]);
    expect(await (await f.manager.findCache('key'))!.readAsBytes(), [1]);
  });

  test(
    'real scan removes unmanaged files and preserves tracked data',
    () async {
      final f = fixture();
      await f.manager.writeCache('key', [1, 2, 3]);
      final unmanaged = File('${f.root.path}/cache/orphan')
        ..writeAsStringSync('unused');
      await f.manager.start();
      expect(await unmanaged.exists(), isFalse);
      expect(f.manager.currentSize, 3);
      expect(await (await f.manager.findCache('key'))!.readAsBytes(), [
        1,
        2,
        3,
      ]);
    },
  );

  test('owned cache paths and size limits are independent', () async {
    final first = fixture();
    final second = fixture();
    await first.manager.writeCache('same', [1]);
    await second.manager.writeCache('same', [2, 3]);
    first.manager.setLimitSize(0);
    await first.manager.checkCache();
    expect(await first.manager.findCache('same'), isNull);
    expect(first.manager.currentSize, 0);
    expect(await (await second.manager.findCache('same'))!.readAsBytes(), [
      2,
      3,
    ]);
  });
}
