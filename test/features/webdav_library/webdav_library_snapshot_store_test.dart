import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/webdav_library/webdav_library_cache.dart';
import 'package:venera_next/features/webdav_library/webdav_library_config.dart';
import 'package:venera_next/features/webdav_library/webdav_library_entries.dart';
import 'package:venera_next/features/webdav_library/webdav_library_session.dart';
import 'package:venera_next/features/webdav_library/webdav_library_snapshot.dart';
import 'package:venera_next/features/webdav_library/webdav_library_snapshot_store.dart';
import 'package:venera_next/features/webdav_library/webdav_library_transport.dart';

const _pages = [WebDavLibraryEntry(name: '001.jpg', isDirectory: false)];

class _Read {
  final response = Completer<List<WebDavLibraryEntry>>();
  final enteredCleanup = Completer<void>();
  final releaseCleanup = Completer<void>();
  bool finished = false;

  Future<List<WebDavLibraryEntry>> run() async {
    try {
      return await response.future;
    } finally {
      enteredCleanup.complete();
      await releaseCleanup.future;
      finished = true;
    }
  }

  void finish([List<WebDavLibraryEntry> pages = _pages]) {
    if (!response.isCompleted) response.complete(pages);
    if (!releaseCleanup.isCompleted) releaseCleanup.complete();
  }
}

class _Ops extends WebDavLibraryOps {
  final paths = <String>[];
  final reads = <_Read>[];

  @override
  Future<List<WebDavLibraryEntry>> readDir(
    WebDavLibraryConfig config,
    String remotePath,
  ) {
    paths.add(remotePath);
    final read = _Read();
    reads.add(read);
    return read.run();
  }

  @override
  Future<String> readText(
    WebDavLibraryConfig config,
    String remotePath,
  ) async => '{}';

  @override
  Future<void> test(WebDavLibraryConfig config) async {}
}

class _Fixture {
  _Fixture({WebDavLibraryCache Function(String)? createCache}) {
    cache = (createCache ?? WebDavLibraryCache.new)(
      '${directory.path}/library.db',
    );
    store = WebDavLibrarySnapshotStore(cache);
    session = WebDavLibrarySession(config, ops, isCurrent: () => true);
  }

  final directory = Directory.systemTemp.createTempSync('webdav-snapshots-');
  final config = WebDavLibraryConfig(
    url: 'https://example.test',
    user: 'reader',
    pass: 'password',
    remotePath: '/books/',
  );
  final ops = _Ops();
  late final WebDavLibraryCache cache;
  late final WebDavLibrarySnapshotStore store;
  late final WebDavLibrarySession session;

  Future<WebDavComicSnapshot> load(String id, {bool force = false}) {
    final result = store.load(session, id, forceRefresh: force);
    result.ignore();
    return result;
  }

  Future<void> dispose() async {
    final closing = store.closeAndWait();
    for (final read in ops.reads) {
      read.finish();
    }
    await closing;
    cache.dispose();
    await directory.delete(recursive: true);
  }
}

class _CommitCache extends WebDavLibraryCache {
  _CommitCache(super.path);

  void Function()? duringCommit;
  Object? commitError;
  final events = <String>[];

  @override
  void upsertSnapshot(String configKey, WebDavLibraryCachedComic comic) {
    events.add('commit started');
    try {
      duringCommit?.call();
      final error = commitError;
      if (error != null) throw error;
      super.upsertSnapshot(configKey, comic);
    } finally {
      events.add('commit finally');
    }
  }
}

void main() {
  test(
    'concurrent loads share a build and cache only its completed result',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      final first = fixture.load('Book');
      final second = fixture.load('Book');
      expect(fixture.ops.reads, hasLength(1));
      fixture.ops.reads.single.finish();
      final snapshot = await first;
      expect(await second, same(snapshot));
      expect(await fixture.load('Book'), same(snapshot));
      expect(fixture.ops.reads, hasLength(1));
      expect(
        fixture.cache.find(fixture.config.cacheKey, 'Book')!.isReady,
        isTrue,
      );
      final refresh = fixture.load('Book', force: true);
      expect(fixture.ops.reads, hasLength(2));
      fixture.ops.reads.last.finish();
      expect(await refresh, isNot(same(snapshot)));
    },
  );

  test(
    'clear admits a new version while old completion cannot overwrite it',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      final old = fixture.load('Book');
      final checkedOld = expectLater(
        old,
        throwsA(isA<WebDavLibraryCancelled>()),
      );
      fixture.store.clear();
      final current = fixture.load('Book');
      expect(fixture.ops.reads, hasLength(2));
      fixture.ops.reads.last.finish([
        const WebDavLibraryEntry(name: 'new.jpg', isDirectory: false),
      ]);
      final latest = await current;
      fixture.ops.reads.first.finish([
        const WebDavLibraryEntry(name: 'old.jpg', isDirectory: false),
      ]);
      await checkedOld;
      expect(await fixture.load('Book'), same(latest));
      expect(
        fixture.cache.find(fixture.config.cacheKey, 'Book')!.cover,
        '/books/Book/new.jpg',
      );
    },
  );

  test(
    'close retains all cleared versions until each build finally finishes',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      final loads = <Future<WebDavComicSnapshot>>[];
      for (var version = 0; version < 3; version++) {
        loads.add(fixture.load('Book', force: true));
        fixture.store.clear();
      }
      final checked = [
        for (final load in loads)
          expectLater(load, throwsA(isA<WebDavLibraryCancelled>())),
      ];
      final closing = fixture.store.closeAndWait();
      expect(fixture.store.closeAndWait(), same(closing));
      var closed = false;
      unawaited(closing.then((_) => closed = true));
      fixture.ops.reads[2].finish();
      fixture.ops.reads[0].finish();
      fixture.ops.reads[1].response.complete(_pages);
      await fixture.ops.reads[1].enteredCleanup.future;
      await pumpEventQueue();
      expect(closed, isFalse);
      expect(fixture.ops.reads[1].finished, isFalse);
      fixture.ops.reads[1].releaseCleanup.complete();
      await Future.wait(checked);
      await closing;
      expect(fixture.ops.reads.every((read) => read.finished), isTrue);
      expect(fixture.cache.find(fixture.config.cacheKey, 'Book'), isNull);
    },
  );

  test(
    'close immediately rejects cached and new loads without owning disk disposal',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      final seed = fixture.load('Cached');
      fixture.ops.reads.single.finish();
      await seed;
      final pending = fixture.load('Pending');
      final checked = expectLater(
        pending,
        throwsA(isA<WebDavLibraryCancelled>()),
      );
      final closing = fixture.store.closeAndWait();
      await expectLater(fixture.load('Cached'), throwsStateError);
      await expectLater(fixture.load('New', force: true), throwsStateError);
      expect(fixture.ops.reads, hasLength(2));
      fixture.ops.reads.last.finish();
      await checked;
      await closing;
      expect(
        fixture.cache.find(fixture.config.cacheKey, 'Cached')!.isReady,
        isTrue,
      );
      expect(fixture.cache.find(fixture.config.cacheKey, 'Pending'), isNull);
      await expectLater(fixture.store.prepareForExit(), throwsStateError);
    },
  );

  test(
    'load failures and cancellation still drain all independent builds',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      final failed = fixture.load('Failure', force: true);
      final cancelled = fixture.load('Cancelled', force: true);
      final malformed = fixture.load('Malformed', force: true);
      final failure = StateError('remote unavailable');
      final checked = [
        expectLater(failed, throwsA(same(failure))),
        expectLater(cancelled, throwsA(isA<WebDavLibraryCancelled>())),
        expectLater(malformed, throwsA(isA<FormatException>())),
      ];
      final closing = fixture.store.closeAndWait();
      var closed = false;
      unawaited(closing.then((_) => closed = true));
      fixture.ops.reads[0].response.completeError(failure);
      fixture.ops.reads[0].releaseCleanup.complete();
      fixture.ops.reads[1].finish();
      fixture.ops.reads[2].response.complete([]);
      await fixture.ops.reads[2].enteredCleanup.future;
      await pumpEventQueue();
      expect(closed, isFalse);
      fixture.ops.reads[2].releaseCleanup.complete();
      await Future.wait(checked);
      await closing;
      expect(fixture.ops.reads.every((read) => read.finished), isTrue);
    },
  );

  test(
    'preparation freezes loads and waits for invalidated build cleanup',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      final pending = fixture.load('Book');
      final checked = expectLater(
        pending,
        throwsA(isA<WebDavLibraryCancelled>()),
      );
      final preparing = fixture.store.prepareForExit();
      expect(fixture.store.prepareForExit(), same(preparing));
      await expectLater(fixture.load('Book'), throwsStateError);
      await expectLater(fixture.load('Other'), throwsStateError);
      var ready = false;
      unawaited(preparing.then((_) => ready = true));
      fixture.ops.reads.single.response.complete(_pages);
      await fixture.ops.reads.single.enteredCleanup.future;
      await pumpEventQueue();
      expect(ready, isFalse);
      fixture.ops.reads.single.releaseCleanup.complete();
      await checked;
      final release = await preparing;
      expect(fixture.cache.find(fixture.config.cacheKey, 'Book'), isNull);
      await expectLater(fixture.load('Book'), throwsStateError);
      release();
      release();
      final retried = fixture.load('Book');
      fixture.ops.reads.last.finish();
      expect((await retried).cover, '/books/Book/001.jpg');
      expect(fixture.ops.reads, hasLength(2));
    },
  );

  test(
    'preparation joins work failures and release permits a fresh retry',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      final failed = fixture.load('Failure', force: true);
      fixture.store.clear();
      final pending = fixture.load('Pending', force: true);
      final failure = StateError('request failed');
      final checked = [
        expectLater(failed, throwsA(same(failure))),
        expectLater(pending, throwsA(isA<WebDavLibraryCancelled>())),
      ];
      final preparing = fixture.store.prepareForExit();
      var ready = false;
      unawaited(preparing.then((_) => ready = true));
      fixture.ops.reads.first.response.completeError(failure);
      fixture.ops.reads.first.releaseCleanup.complete();
      await pumpEventQueue();
      expect(ready, isFalse);
      fixture.ops.reads.last.finish();
      await Future.wait(checked);
      final release = await preparing;
      release();
      final retried = fixture.load('Failure');
      fixture.ops.reads.last.finish();
      expect((await retried).title, 'Failure');
    },
  );

  test(
    'stale releases cannot lift another preparation or reopen a closed store',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      final first = await fixture.store.prepareForExit();
      first();
      final second = await fixture.store.prepareForExit();
      first();
      await expectLater(fixture.load('Book'), throwsStateError);
      second();
      second();
      final loaded = fixture.load('Book');
      fixture.ops.reads.single.finish();
      await loaded;
      await fixture.store.closeAndWait();
      first();
      second();
      await expectLater(fixture.load('Book'), throwsStateError);
    },
  );

  test(
    'close during preparation joins the same work and disables restoration',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      final loaded = fixture.load('Book');
      final checked = expectLater(
        loaded,
        throwsA(isA<WebDavLibraryCancelled>()),
      );
      final preparing = fixture.store.prepareForExit();
      final closing = fixture.store.closeAndWait();
      var closed = false;
      unawaited(closing.then((_) => closed = true));
      await pumpEventQueue();
      expect(closed, isFalse);
      fixture.ops.reads.single.finish();
      await checked;
      final release = await preparing;
      await closing;
      release();
      await expectLater(fixture.load('Book'), throwsStateError);
    },
  );

  test('snapshot owners keep independent gates, builds and caches', () async {
    final first = _Fixture();
    final second = _Fixture();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    final old = first.load('Book');
    final checked = expectLater(old, throwsA(isA<WebDavLibraryCancelled>()));
    final preparing = first.store.prepareForExit();
    final other = second.load('Book');
    second.ops.reads.single.finish();
    final snapshot = await other;
    expect(second.cache.find(second.config.cacheKey, 'Book')!.isReady, isTrue);
    first.ops.reads.single.finish();
    await checked;
    final release = await preparing;
    await first.store.closeAndWait();
    release();
    expect(await second.load('Book'), same(snapshot));
  });

  test(
    'preparing inside an accepted commit waits for finally and prevents memory refill',
    () async {
      final fixture = _Fixture(createCache: _CommitCache.new);
      addTearDown(fixture.dispose);
      final cache = fixture.cache as _CommitCache;
      late Future<void Function()> preparing;
      var ready = false;
      cache.duringCommit = () {
        preparing = fixture.store.prepareForExit();
        unawaited(
          preparing.then((_) {
            ready = true;
            cache.events.add('prepared');
          }),
        );
        expect(ready, isFalse);
      };
      final pending = fixture.load('Book');
      final checked = expectLater(
        pending,
        throwsA(isA<WebDavLibraryCancelled>()),
      );
      fixture.ops.reads.single.finish();
      await checked;
      final release = await preparing;
      expect(cache.events, ['commit started', 'commit finally', 'prepared']);
      cache.duringCommit = null;
      cache.clear(fixture.config.cacheKey);
      release();
      final fresh = fixture.load('Book');
      expect(fixture.ops.reads, hasLength(2));
      fixture.ops.reads.last.finish();
      await fresh;
    },
  );

  test(
    'a failed commit completes its finally without turning shutdown into a load error',
    () async {
      final fixture = _Fixture(createCache: _CommitCache.new);
      addTearDown(fixture.dispose);
      final cache = fixture.cache as _CommitCache;
      final failure = StateError('disk commit failed');
      cache.commitError = failure;
      late Future<void> closing;
      cache.duringCommit = () {
        closing = fixture.store.closeAndWait();
        unawaited(closing.then((_) => cache.events.add('closed')));
      };
      final pending = fixture.load('Book');
      final checked = expectLater(pending, throwsA(same(failure)));
      fixture.ops.reads.single.finish();
      await checked;
      await closing;
      expect(cache.events, ['commit started', 'commit finally', 'closed']);
      expect(cache.find(fixture.config.cacheKey, 'Book'), isNull);
    },
  );
}
