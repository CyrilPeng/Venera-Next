import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/comic_cover.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/comic_cover.dart';
import 'package:venera_next/foundation/cover_cache_record.dart';
import 'package:venera_next/network/images.dart';
import 'package:venera_next/network/request_scope.dart';

import '../support/cover_cache_fixture.dart';

const _id = ComicCoverIdentity('source', 'comic');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'changed URL publishes a validated image and preserves the previous version',
    () async {
      final f = CoverCacheFixture();
      await f.manager.refresh(_id, f.url);
      final before = f.manager.snapshotFor(_id)!;
      final originalBytes = f.bytes;
      f.url = 'https://fixture.invalid/new.png';
      f.bytes = coverPng(200);
      await f.manager.refresh(_id, before.url);
      final after = f.manager.snapshotFor(_id)!;
      expect(after.url, f.url);
      expect(after.cacheKey, isNot(before.cacheKey));
      expect(
        await (await f.cache.findCache(after.cacheKey!))!.readAsBytes(),
        f.bytes,
      );
      expect(
        await (await f.cache.findCache(before.cacheKey!))!.readAsBytes(),
        originalBytes,
      );
      expect(f.publications, [(_id, before.url), (_id, f.url)]);
    },
  );

  test(
    'new bytes at the same URL have a different immutable Flutter/disk identity',
    () async {
      final f = CoverCacheFixture();
      await f.manager.refresh(_id, f.url);
      final original = f.manager.snapshotFor(_id)!;
      f.bytes = coverPng(201);
      await f.manager.refresh(_id, f.url);
      final updated = f.manager.snapshotFor(_id)!;
      expect(updated.url, original.url);
      expect(updated.cacheKey, isNot(original.cacheKey));
      expect(f.forced, [true, true]);
    },
  );

  test(
    'accessing a cache does not postpone the fixed cover validation deadline',
    () async {
      final f = CoverCacheFixture();
      await f.manager.refresh(_id, f.url);
      final key = f.manager.snapshotFor(_id)!.cacheKey!;
      final checkedAt = f.now;
      f.now = f.now.add(const Duration(hours: 23));
      await f.cache.findCache(key);
      final fresh = f.manager.acquire(_id, f.url);
      await pumpEventQueue();
      fresh.release();
      expect(f.metadataCalls, 1);
      expect(
        (await f.cache.readCoverRecord(_id.storageKey))!.checkedAt,
        checkedAt,
      );
      f.now = f.now.add(const Duration(hours: 1));
      f.bytes = coverPng(202);
      final expired = f.manager.acquire(_id, f.url);
      await coverChanged(expired, (snapshot) => snapshot.cacheKey != key);
      expired.release();
      expect(f.metadataCalls, 2);
      expect(f.forced, [true, false]);
      expect((await f.cache.readCoverRecord(_id.storageKey))!.checkedAt, f.now);
    },
  );

  test(
    'opening details with the same URL keeps the validation schedule',
    () async {
      final f = CoverCacheFixture();
      await f.manager.refresh(_id, f.url);
      final key = f.manager.snapshotFor(_id)!.cacheKey;
      final lease = f.manager.acquire(_id, f.url);
      addTearDown(lease.release);
      f.now = f.now.add(const Duration(hours: 23));
      var published = false;
      await f.manager.captureMetadata(_id, (_, check) async {
        check();
        published = true;
      })(f.url);
      await pumpEventQueue();
      expect(published, true);
      expect(lease.snapshot.cacheKey, key);
      expect(f.imageCalls, 1);
    },
  );

  test(
    'an evicted version cannot be filled by the mutable thumbnail URL',
    () async {
      final f = CoverCacheFixture();
      final previousCache = CacheManager.instance;
      CacheManager.instance = f.cache;
      addTearDown(() => CacheManager.instance = previousCache);
      await f.manager.refresh(_id, f.url);
      final first = f.manager.snapshotFor(_id)!;
      await f.cache.delete(first.cacheKey!);
      f.bytes = coverPng(203);
      final lease = f.manager.acquire(_id, f.url);
      addTearDown(lease.release);
      final reloaded = coverChanged(
        lease,
        (snapshot) =>
            snapshot.cacheKey != null && snapshot.cacheKey != first.cacheKey,
      );
      final chunks = StreamController<ImageChunkEvent>.broadcast();
      addTearDown(chunks.close);
      await expectLater(
        validatedComicCoverProvider(f.manager, _id, first)!.load(chunks, () {}),
        throwsA(anything),
      );
      await reloaded;
      expect(await f.cache.findCache(first.cacheKey!), isNull);
      expect(
        (await f.cache.readCoverRecord(_id.storageKey))!.cacheKey,
        lease.snapshot.cacheKey,
      );
    },
  );

  test(
    'validation receipts survive reopening without a new source request',
    () async {
      final f = CoverCacheFixture();
      await f.manager.refresh(_id, f.url);
      final previous = f.manager.snapshotFor(_id)!;
      await f.manager.dispose();
      final reopened = ComicCoverManager(
        cache: f.cache,
        now: () => f.now,
        loadMetadata: (_, _) =>
            throw StateError('A fresh record must not reload metadata'),
      );
      try {
        final lease = reopened.acquire(
          _id,
          'https://fixture.invalid/stale-list.png',
        );
        await coverChanged(
          lease,
          (snapshot) => snapshot.cacheKey == previous.cacheKey,
        );
        expect(lease.snapshot.url, previous.url);
        lease.release();
      } finally {
        await reopened.dispose();
      }
    },
  );

  test(
    'a corrupt image never replaces the old URL, bytes or successful timestamp',
    () async {
      final f = CoverCacheFixture();
      await f.manager.refresh(_id, f.url);
      final before = f.manager.snapshotFor(_id)!;
      final receipt = await f.cache.readCoverRecord(_id.storageKey);
      final previousBytes = f.bytes;
      f.now = f.now.add(const Duration(days: 2));
      f.url = 'https://fixture.invalid/error.html';
      f.bytes = Uint8List.fromList('<html>source unavailable</html>'.codeUnits);
      await expectLater(f.manager.refresh(_id, before.url), throwsA(anything));
      expect(f.manager.snapshotFor(_id)!.url, before.url);
      expect(f.manager.snapshotFor(_id)!.cacheKey, before.cacheKey);
      expect(
        (await f.cache.readCoverRecord(_id.storageKey))!.checkedAt,
        receipt!.checkedAt,
      );
      expect(
        await (await f.cache.findCache(before.cacheKey!))!.readAsBytes(),
        previousBytes,
      );
      expect(f.publications, [(_id, before.url)]);
    },
  );

  test(
    'background metadata reads share two slots and do not process retired covers',
    () async {
      final gates = <String, Completer<void>>{};
      final reads = <String>[];
      final f = CoverCacheFixture(
        metadata: (identity, scope) async {
          reads.add(identity.id);
          await (gates[identity.id] = Completer<void>()).future;
          scope.check();
          return ComicCoverMetadata(
            'https://fixture.invalid/${identity.id}.png',
            (_, check) async => check(),
          );
        },
      );
      final leases = [
        for (var i = 0; i < 4; i++)
          f.manager.acquire(ComicCoverIdentity('source', '$i'), f.url),
      ];
      addTearDown(() {
        for (final gate in gates.values) {
          if (!gate.isCompleted) gate.complete();
        }
        for (final lease in leases) {
          lease.release();
        }
      });
      await pumpEventQueue();
      expect(reads, ['0', '1']);
      leases[2].release();
      leases[3].release();
      gates['0']!.complete();
      gates['1']!.complete();
      await Future.wait(
        leases
            .take(2)
            .map(
              (lease) =>
                  coverChanged(lease, (snapshot) => snapshot.cacheKey != null),
            ),
      );
      expect(reads, ['0', '1']);
    },
  );

  test(
    'closing joins an original metadata future and prevents its late publication',
    () async {
      final entered = Completer<void>();
      final finish = Completer<void>();
      var publications = 0;
      final f = CoverCacheFixture(
        metadata: (_, scope) async {
          entered.complete();
          await finish.future;
          scope.check();
          return ComicCoverMetadata('https://fixture.invalid/late.png', (
            _,
            check,
          ) async {
            check();
            publications++;
          });
        },
      );
      final lease = f.manager.acquire(_id, f.url);
      await entered.future;
      var closed = false;
      final closing = f.manager.dispose().then((_) => closed = true);
      await pumpEventQueue();
      expect(closed, false);
      finish.complete();
      await closing;
      lease.release();
      expect(publications, 0);
      expect(await f.cache.readCoverRecord(_id.storageKey), isNull);
    },
  );

  test(
    'newer metadata invalidates the older response before any publication',
    () async {
      final f = CoverCacheFixture();
      final saved = <String>[];
      final first = f.manager.captureMetadata(_id, (url, check) async {
        check();
        saved.add(url);
      });
      final second = f.manager.captureMetadata(_id, (url, check) async {
        check();
        saved.add(url);
      });
      await second('https://fixture.invalid/new.png');
      await expectLater(
        first('https://fixture.invalid/old.png'),
        throwsA(isA<RequestCancelled>()),
      );
      expect(saved, ['https://fixture.invalid/new.png']);
      expect(f.metadataCalls, 0);
    },
  );

  test(
    'source replacement while bytes are loading cannot commit a cover',
    () async {
      final entered = Completer<void>();
      final finish = Completer<void>();
      var owner = Object();
      final f = CoverCacheFixture(
        captureOwner: (_) {
          final original = owner;
          return () {
            if (!identical(owner, original)) throw const RequestCancelled();
          };
        },
        image: (_, _, _, _, _, _) async {
          entered.complete();
          await finish.future;
          return ThumbnailRefreshResult(
            bytes: coverPng(204),
            validators: const ThumbnailValidators(requestKey: 'owner'),
            notModified: false,
          );
        },
      );
      final refresh = f.manager.refresh(_id, f.url);
      final checked = expectLater(refresh, throwsA(isA<RequestCancelled>()));
      await entered.future;
      owner = Object();
      finish.complete();
      await checked;
      expect(f.publications, isEmpty);
      expect(await f.cache.readCoverRecord(_id.storageKey), isNull);
    },
  );

  test('cache clear removes disposable cover validation receipts', () async {
    final f = CoverCacheFixture();
    await f.manager.refresh(_id, f.url);
    await f.cache.clear();
    expect(await f.cache.readCoverRecord(_id.storageKey), isNull);
  });
}
