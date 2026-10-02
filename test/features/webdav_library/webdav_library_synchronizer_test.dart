import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/webdav_library/webdav_library_api.dart';
import 'package:venera_next/features/webdav_library/webdav_library_session.dart';
import 'package:venera_next/features/webdav_library/webdav_library_snapshot_store.dart';

void main() {
  late Directory directory;
  late WebDavLibraryCache cache;
  late WebDavLibrarySnapshotStore snapshots;
  late WebDavLibrarySession session;
  late WebDavLibrarySynchronizer synchronizer;
  late WebDavLibrarySettings settings;
  late _Ops ops;
  late int now;
  late int changes;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('webdav-coordinator-');
    cache = WebDavLibraryCache('${directory.path}/library.db');
    snapshots = WebDavLibrarySnapshotStore(cache);
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

  tearDown(() {
    synchronizer.dispose();
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
