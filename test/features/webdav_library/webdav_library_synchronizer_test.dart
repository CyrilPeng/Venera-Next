import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/webdav_library/webdav_library_api.dart';
import 'package:venera_next/features/webdav_library/webdav_library_session.dart';
import 'package:venera_next/features/webdav_library/webdav_library_snapshot_store.dart';
import 'package:venera_next/foundation/log.dart';

void main() {
  late Directory directory;
  late WebDavLibraryCache cache;
  late _Snapshots snapshots;
  late WebDavLibrarySession session;
  late WebDavLibrarySynchronizer synchronizer;
  late WebDavLibrarySettings settings;
  late _Ops ops;
  late int now;
  late int changes;
  late bool expectsCloseFailure;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('webdav-coordinator-');
    cache = WebDavLibraryCache('${directory.path}/library.db');
    snapshots = _Snapshots(cache);
    expectsCloseFailure = false;
    ops = _Ops();
    settings = WebDavLibrarySettings(
      connection: WebDavLibraryConfig(
        url: 'https://example.com',
        user: '',
        pass: '',
        remotePath: '/books/',
      ),
      autoSync: true,
      intervalMinutes: 15,
    );
    session = WebDavLibrarySession(
      settings.connection,
      ops,
      isCurrent: () => true,
    );
    now = 1000000;
    changes = 0;
    synchronizer = WebDavLibrarySynchronizer(
      cache: cache,
      snapshots: snapshots,
      readSettings: () => settings,
      currentSession: () => session,
      onContentChanged: () => changes++,
      nowMilliseconds: () => now,
    );
  });

  tearDown(() async {
    if (expectsCloseFailure) {
      await synchronizer.closeAndWait().catchError((_) {});
    } else {
      await synchronizer.closeAndWait();
    }
    session.cancel();
    ops.dispose();
    cache.dispose();
    directory.deleteSync(recursive: true);
  });

  test(
    'automatic updates respect disabled settings and exact interval boundary',
    () async {
      cache.setLastSuccessfulSync(settings.connection.cacheKey, now);
      now += const Duration(minutes: 15).inMilliseconds - 1;
      synchronizer.checkForAutomaticSync();
      await Future<void>.delayed(Duration.zero);
      expect(ops.paths, isEmpty);
      now++;
      synchronizer.checkForAutomaticSync();
      expect((await synchronizer.synchronize()).success, isTrue);
      expect(ops.paths, ['/books/', '/books/Book/']);
      expect(synchronizer.status.value.lastSuccessfulSync, now);

      ops.paths.clear();
      settings = WebDavLibrarySettings(
        connection: settings.connection,
        autoSync: false,
        intervalMinutes: 15,
      );
      now += const Duration(days: 1).inMilliseconds;
      synchronizer.checkForAutomaticSync();
      await Future<void>.delayed(Duration.zero);
      expect(ops.paths, isEmpty);
    },
  );

  test(
    'concurrent callers share one run, including force while already active',
    () async {
      final entered = Completer<void>();
      final root = Completer<List<WebDavLibraryEntry>>();
      ops.read = (path) {
        entered.complete();
        return root.future;
      };
      final first = synchronizer.synchronize();
      await entered.future;
      final second = synchronizer.synchronize(force: true);
      expect(second, same(first));
      root.complete([]);
      expect((await first).success, isTrue);
      expect(ops.paths, ['/books/']);
    },
  );

  test('index availability does not wait for metadata completion', () async {
    final metadata = Completer<List<WebDavLibraryEntry>>();
    ops.read = (path) async => path == '/books/' ? _Ops.root : metadata.future;
    final index = await synchronizer.ensureIndex(session);
    expect(index.success, isTrue);
    expect(cache.hasDirectoryIndex(settings.connection.cacheKey), isTrue);
    expect(synchronizer.status.value.isSyncing, isTrue);
    metadata.complete(_Ops.pages);
    expect((await synchronizer.synchronize()).success, isTrue);
    expect(cache.find(settings.connection.cacheKey, 'Book')!.isReady, isTrue);
  });

  test(
    'invalidating a pending run admits a replacement without stale status',
    () async {
      final entered = Completer<void>();
      final oldRoot = Completer<List<WebDavLibraryEntry>>();
      ops.read = (_) {
        entered.complete();
        return oldRoot.future;
      };
      final previous = synchronizer.synchronize();
      await entered.future;
      synchronizer.invalidate();
      ops.read = (path) async => path == '/books/' ? _Ops.root : _Ops.pages;
      expect((await synchronizer.synchronize()).success, isTrue);
      final status = synchronizer.status.value;
      final version = changes;
      oldRoot.complete([]);
      expect((await previous).error, isTrue);
      expect(synchronizer.status.value, same(status));
      expect(changes, version);
      expect(cache.count(settings.connection.cacheKey), 1);
    },
  );

  test(
    'disposing coordinator cancels its run but preserves caller-owned reads',
    () async {
      final entered = Completer<void>();
      final oldRoot = Completer<List<WebDavLibraryEntry>>();
      ops.read = (_) {
        entered.complete();
        return oldRoot.future;
      };
      final pending = synchronizer.synchronize();
      await entered.future;
      synchronizer.dispose();
      oldRoot.complete(_Ops.root);
      expect((await pending).error, isTrue);
      expect(session.isActive, isTrue);
      expect(cache.hasDirectoryIndex(settings.connection.cacheKey), isFalse);
      ops.read = (_) async => _Ops.pages;
      expect((await snapshots.load(session, 'Book')).rootImages, hasLength(1));
      expect(() => synchronizer.synchronize(), throwsStateError);
      await expectLater(synchronizer.ensureIndex(session), throwsStateError);
    },
  );

  test('close waits for replaced runs as well as the current run', () async {
    final roots = <Completer<List<WebDavLibraryEntry>>>[];
    ops.read = (_) {
      final root = Completer<List<WebDavLibraryEntry>>();
      roots.add(root);
      return root.future;
    };
    final previous = synchronizer.synchronize();
    await pumpEventQueue();
    synchronizer.invalidate();
    final current = synchronizer.synchronize();
    await pumpEventQueue();
    expect(roots, hasLength(2));

    final closing = synchronizer.closeAndWait();
    expect(identical(closing, synchronizer.closeAndWait()), isTrue);
    var closed = false;
    unawaited(closing.then((_) => closed = true));
    expect(() => synchronizer.synchronize(), throwsStateError);
    await expectLater(synchronizer.ensureIndex(session), throwsStateError);
    synchronizer.checkForAutomaticSync();
    expect(ops.paths, hasLength(2));
    roots.last.complete(_Ops.root);
    expect((await current).error, isTrue);
    await pumpEventQueue();
    expect(closed, isFalse);
    expect(cache.hasDirectoryIndex(settings.connection.cacheKey), isFalse);

    roots.first.complete(_Ops.root);
    expect((await previous).error, isTrue);
    await closing;
    expect(closed, isTrue);
    expect(changes, 0);
    expect(session.isActive, isTrue);
    expect(identical(closing, synchronizer.closeAndWait()), isTrue);
  });

  test(
    'preparation holds every entry point and isolates stale releases',
    () async {
      cache.setLastSuccessfulSync(settings.connection.cacheKey, 123);
      final root = Completer<List<WebDavLibraryEntry>>();
      ops.read = (_) => root.future;
      final pending = synchronizer.synchronize();
      await pumpEventQueue();
      final preparation = synchronizer.prepareForExit();
      expect(identical(preparation, synchronizer.prepareForExit()), isTrue);
      expect(synchronizer.status.value.isSyncing, isFalse);
      expect(synchronizer.status.value.lastSuccessfulSync, 123);
      expect((await synchronizer.synchronize(force: true)).error, isTrue);
      expect((await synchronizer.ensureIndex(session)).error, isTrue);
      synchronizer.checkForAutomaticSync();
      synchronizer.updateSyncStatusFromCache();
      expect(ops.paths, ['/books/']);
      var prepared = false;
      unawaited(preparation.then((_) => prepared = true));
      await pumpEventQueue();
      expect(prepared, isFalse);

      root.complete(_Ops.root);
      expect((await pending).error, isTrue);
      final release = await preparation;
      release();
      ops.read = (path) async => path == '/books/' ? _Ops.root : _Ops.pages;
      expect((await synchronizer.synchronize()).success, isTrue);
      expect(cache.hasDirectoryIndex(settings.connection.cacheKey), isTrue);

      final nextPreparation = synchronizer.prepareForExit();
      expect(identical(preparation, nextPreparation), isFalse);
      final nextRelease = await nextPreparation;
      release();
      expect((await synchronizer.ensureIndex(session)).error, isTrue);
      expect((await synchronizer.synchronize()).error, isTrue);
      final requestCount = ops.paths.length;
      synchronizer.checkForAutomaticSync();
      expect(ops.paths, hasLength(requestCount));
      nextRelease();
      nextRelease();
      expect((await synchronizer.ensureIndex(session)).success, isTrue);
    },
  );

  test(
    'preparation invalidates a scheduled run before it opens storage',
    () async {
      final pending = synchronizer.synchronize();
      final release = await synchronizer.prepareForExit();
      expect((await pending).error, isTrue);
      expect(ops.paths, isEmpty);
      expect(File(cache.path).existsSync(), isFalse);
      expect(changes, 0);
      release();
      expect((await synchronizer.synchronize()).success, isTrue);
    },
  );

  test(
    'disposing during preparation waits and makes its release inert',
    () async {
      final root = Completer<List<WebDavLibraryEntry>>();
      ops.read = (_) => root.future;
      final pending = synchronizer.synchronize();
      await pumpEventQueue();
      final preparation = synchronizer.prepareForExit();
      synchronizer.dispose();
      final closing = synchronizer.closeAndWait();
      var closed = false;
      unawaited(closing.then((_) => closed = true));
      await pumpEventQueue();
      expect(closed, isFalse);
      root.complete([]);
      expect((await pending).error, isTrue);
      final release = await preparation;
      await closing;
      release();
      synchronizer.checkForAutomaticSync();
      expect(ops.paths, ['/books/']);
      expect(() => synchronizer.synchronize(), throwsStateError);
      await expectLater(synchronizer.prepareForExit(), throwsStateError);
    },
  );

  test(
    'failed preparation drains all generations and permits a later retry',
    () async {
      final roots = <Completer<List<WebDavLibraryEntry>>>[];
      ops.read = (_) {
        final root = Completer<List<WebDavLibraryEntry>>();
        roots.add(root);
        return root.future;
      };
      final first = synchronizer.synchronize();
      await pumpEventQueue();
      synchronizer.invalidate();
      final second = synchronizer.synchronize();
      await pumpEventQueue();
      final failure = StateError('snapshot cleanup');
      snapshots.clearFailure = failure;
      final preparation = synchronizer.prepareForExit();
      final checked = expectLater(
        preparation,
        throwsA(
          isA<WebDavLibrarySyncLifecycleFailure>()
              .having(
                (error) => error.failures.single.operation,
                'operation',
                'snapshots',
              )
              .having(
                (error) => error.failures.single.error,
                'cleanup failure',
                same(failure),
              ),
        ),
      );
      var completed = false;
      preparation.then<void>(
        (_) {
          completed = true;
        },
        onError: (Object _, StackTrace _) {
          completed = true;
        },
      );
      expect(synchronizer.status.value.isSyncing, isFalse);
      roots.last.complete([]);
      await second;
      await pumpEventQueue();
      expect(completed, isFalse);
      expect((await synchronizer.synchronize()).error, isTrue);
      roots.first.complete([]);
      await first;
      await checked;

      snapshots.clearFailure = null;
      ops.read = (path) async => path == '/books/' ? _Ops.root : _Ops.pages;
      expect((await synchronizer.synchronize()).success, isTrue);
      final release = await synchronizer.prepareForExit();
      release();
    },
  );

  test(
    'close reports cleanup failure only after outstanding work settles',
    () async {
      final root = Completer<List<WebDavLibraryEntry>>();
      ops.read = (_) => root.future;
      final pending = synchronizer.synchronize();
      await pumpEventQueue();
      final failure = StateError('snapshot release');
      snapshots.clearFailure = failure;
      expectsCloseFailure = true;
      Log.isMuted = true;
      addTearDown(() => Log.isMuted = false);
      final closing = synchronizer.closeAndWait();
      late WebDavLibrarySyncLifecycleFailure actual;
      final checked = expectLater(
        closing,
        throwsA(
          isA<WebDavLibrarySyncLifecycleFailure>().having(
            (error) {
              actual = error;
              return error.failures.single.error;
            },
            'cleanup failure',
            same(failure),
          ),
        ),
      );
      var closed = false;
      closing.then<void>(
        (_) {
          closed = true;
        },
        onError: (Object _, StackTrace _) {
          closed = true;
        },
      );
      expect(() => synchronizer.status.addListener(() {}), throwsFlutterError);
      await pumpEventQueue();
      expect(closed, isFalse);
      expect(cache.count(settings.connection.cacheKey), 0);
      root.complete(_Ops.root);
      expect((await pending).error, isTrue);
      await checked;
      expect(identical(closing, synchronizer.closeAndWait()), isTrue);
      await expectLater(synchronizer.closeAndWait(), throwsA(same(actual)));
    },
  );
}

class _Snapshots extends WebDavLibrarySnapshotStore {
  _Snapshots(super.cache);
  Object? clearFailure;

  @override
  void clear() {
    final failure = clearFailure;
    if (failure != null) throw failure;
    super.clear();
  }
}

class _Ops extends WebDavLibraryOps {
  static const root = [WebDavLibraryEntry(name: 'Book', isDirectory: true)];
  static const pages = [
    WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
  ];
  final paths = <String>[];
  Future<List<WebDavLibraryEntry>> Function(String) read = (path) async =>
      path == '/books/' ? root : pages;

  @override
  Future<List<WebDavLibraryEntry>> readDir(
    WebDavLibraryConfig config,
    String path,
  ) {
    paths.add(path);
    return read(path);
  }

  @override
  Future<String> readText(WebDavLibraryConfig config, String path) async =>
      '{}';

  @override
  Future<void> test(WebDavLibraryConfig config) async {}
}
