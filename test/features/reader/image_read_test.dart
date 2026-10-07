import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/image_position.dart';
import 'package:venera_next/features/reader/image_read.dart';
import 'package:venera_next/features/reader/image_action.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/foundation/file_system.dart' as storage;

void main() {
  late Directory directory;
  late CacheManager? previous;
  late CacheManager cache;
  const first = ReaderImageAddress(
    imageKey: 'same',
    sourceKey: 'source',
    comicId: 'book',
    chapterId: 'one',
  );
  const second = ReaderImageAddress(
    imageKey: 'same',
    sourceKey: 'source',
    comicId: 'book',
    chapterId: 'two',
  );
  setUp(() {
    directory = Directory.systemTemp.createTempSync('image-address-');
    previous = CacheManager.instance;
    cache = CacheManager.open(
      dataPath: directory.path,
      cacheRoot: directory.path,
    );
    CacheManager.instance = cache;
  });
  tearDown(() async {
    await cache.dispose();
    CacheManager.instance = previous;
    directory.deleteSync(recursive: true);
  });

  test(
    'duplicate keys in different chapters read distinct original bytes',
    () async {
      await cache.writeCache(first.cacheKey, [1, 2, 3]);
      await cache.writeCache(second.cacheKey, [4, 5, 6]);
      expect(await readReaderImageBytes(first), [1, 2, 3]);
      expect(await readReaderImageBytes(second), [4, 5, 6]);
    },
  );
  test(
    'missing cached image is absent and local files retain their raw bytes',
    () async {
      expect(await readReaderImageBytes(first), isNull);
      final file = File('${directory.path}/page.bin')
        ..writeAsBytesSync([9, 8, 7]);
      final address = ReaderImageAddress(
        imageKey: 'file://${file.path}',
        sourceKey: null,
        comicId: 'book',
        chapterId: 'one',
      );
      expect(await readReaderImageBytes(address), [9, 8, 7]);
      file.deleteSync();
      await expectLater(
        readReaderImageBytes(address),
        throwsA(isA<FileSystemException>()),
      );
    },
  );
  test(
    'an accepted lookup stays in its original cache and drains on exit',
    () async {
      final file = File('${directory.path}/page.bin')
        ..writeAsBytesSync([3, 2, 1]);
      final lookup = Completer<storage.File?>();
      final original = _PendingCache(lookup.future);
      CacheManager.instance = original;
      final work = ImageWork();
      var consumed = false, closed = false;
      final reading = useReaderImage(
        work: work,
        read: () => readReaderImageBytes(first),
        isCurrent: () => true,
        consume: (_) async => consumed = true,
        onMissing: () => fail('missing'),
        onError: (_) => fail('unexpected'),
      );
      CacheManager.instance = cache;
      final closing = work.dispose().then((_) => closed = true);
      await pumpEventQueue();
      expect(closed, isFalse);
      expect(original.keys, [first.cacheKey]);
      lookup.complete(storage.File(file.path));
      await Future.wait([reading, closing]);
      expect(consumed, isFalse);
      expect(closed, isTrue);
    },
  );
  test(
    'late original-cache failure is retained by the original image owner',
    () async {
      final lookup = Completer<storage.File?>();
      CacheManager.instance = _PendingCache(lookup.future);
      final work = ImageWork();
      final error = StateError('original cache read failed');
      final stack = StackTrace.fromString('original cache stack');
      final reading = useReaderImage(
        work: work,
        read: () => readReaderImageBytes(first),
        isCurrent: () => true,
        consume: (Uint8List _) async => fail('late bytes'),
        onMissing: () => fail('late miss'),
        onError: (_) => fail('late UI'),
      );
      final closing = work.dispose();
      final checked = expectLater(
        closing,
        throwsA(
          predicate(
            (failure) =>
                failure.toString().contains('original cache read failed'),
          ),
        ),
      );
      lookup.completeError(error, stack);
      await reading;
      await checked;
    },
  );
}

class _PendingCache extends Fake implements CacheManager {
  _PendingCache(this.pending);
  final Future<storage.File?> pending;
  final keys = <String>[];
  @override
  Future<storage.File?> findCache(String key) {
    keys.add(key);
    return pending;
  }
}
