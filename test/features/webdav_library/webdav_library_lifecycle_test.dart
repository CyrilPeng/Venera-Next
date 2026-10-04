import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/webdav_library/webdav_library.dart';

void main() {
  late Directory directory;
  late List<WebDavLibrarySource> sources;
  late WebDavLibrarySettings settings;
  late Map<WebDavLibrarySource, Object> expectedCloseFailures;
  late List<void Function()> releaseGates;

  _Gate<T> gate<T>(T fallback) {
    final result = _Gate(fallback);
    releaseGates.add(result.finish);
    return result;
  }

  WebDavLibrarySettings configuration(String password) => WebDavLibrarySettings(
    connection: WebDavLibraryConfig(
      url: 'https://example.com',
      user: 'user',
      pass: password,
      remotePath: '/comics/',
    ),
    autoSync: false,
    intervalMinutes: 360,
  );

  ({WebDavLibrarySource source, WebDavLibraryCache cache}) create(_Ops ops) {
    final cache = WebDavLibraryCache('${directory.path}/${sources.length}.db');
    final source = WebDavLibrarySource(
      readSettings: () => settings,
      cache: cache,
      ops: ops,
    );
    sources.add(source);
    return (source: source, cache: cache);
  }

  setUp(() {
    directory = Directory.systemTemp.createTempSync('webdav-lifetime-');
    sources = [];
    expectedCloseFailures = {};
    releaseGates = [];
    settings = configuration('old');
  });

  tearDown(() async {
    for (final release in releaseGates) {
      release();
    }
    for (final source in sources) {
      final expected = expectedCloseFailures[source];
      if (expected == null) {
        await source.closeAndWait();
      } else {
        await expectLater(source.closeAndWait(), throwsA(same(expected)));
      }
    }
    directory.deleteSync(recursive: true);
  });

  test(
    'transport disposal failure still closes storage and rejects new work',
    () async {
      final ops = _Ops()..disposeError = StateError('transport close failed');
      final library = create(ops);
      library.cache.count('any');
      final closing = library.source.closeAndWait();
      expect(library.source.isDisposed, isTrue);
      await expectLater(
        closing,
        throwsA(
          isA<WebDavLibraryLifecycleFailure>().having(
            (error) {
              expectedCloseFailures[library.source] = error;
              return error.failures.map((failure) => failure.error);
            },
            'cleanup errors',
            [same(ops.disposeError)],
          ),
        ),
      );
      expect(() => library.cache.count('any'), throwsStateError);
      expect(library.source.closeAndWait(), same(closing));
      expect(ops.disposals, 1);
    },
  );

  test(
    'same configuration has independent requests, caches and status',
    () async {
      final blocked = Completer<List<WebDavLibraryEntry>>();
      final firstOps = _Ops()..read = (_, _) => blocked.future;
      final secondOps = _Ops();
      final first = create(firstOps);
      final second = create(secondOps);
      final pending = first.source.loadComicInfo('Book');
      final details = await second.source.loadComicInfo('Book');
      expect(details.success, isTrue);
      expect(first.cache.find(settings.connection.cacheKey, 'Book'), isNull);
      expect(
        second.cache.find(settings.connection.cacheKey, 'Book'),
        isNotNull,
      );
      final closing = first.source.closeAndWait();
      expect(firstOps.disposals, 1);
      expect(secondOps.disposals, 0);
      blocked.complete(_Ops.pages);
      expect((await pending).error, isTrue);
      await closing;
      expect((await second.source.loadComicInfo('Book')).success, isTrue);
    },
  );

  test(
    'dispose before scheduled sync starts resolves without opening storage',
    () async {
      final ops = _Ops();
      final library = create(ops);
      final pending = library.source.synchronizer.synchronize();
      final closing = library.source.closeAndWait();
      expect((await pending).error, isTrue);
      await closing;
      expect(ops.calls, isEmpty);
      expect(File(library.cache.path).existsSync(), isFalse);
      await library.source.closeAndWait();
      expect(ops.disposals, 1);
      expect(() => library.source.synchronizer.synchronize(), throwsStateError);
      expect(() => library.cache.count('any'), throwsStateError);
    },
  );

  test(
    'dispose during root discovery completes index waiters without late writes',
    () async {
      final entered = Completer<void>();
      final response = Completer<List<WebDavLibraryEntry>>();
      final ops = _Ops()
        ..read = (_, _) {
          if (!entered.isCompleted) entered.complete();
          return response.future;
        };
      final library = create(ops);
      var changes = 0;
      library.source.contentVersion.addListener(() => changes++);
      final pending = library.source.loadComics(1);
      await entered.future;
      final closing = library.source.closeAndWait();
      response.complete([
        const WebDavLibraryEntry(name: 'Old', isDirectory: true),
      ]);
      expect((await pending).error, isTrue);
      await closing;
      final reopened = WebDavLibraryCache(library.cache.path);
      expect(reopened.count(settings.connection.cacheKey), 0);
      expect(reopened.hasDirectoryIndex(settings.connection.cacheKey), isFalse);
      reopened.dispose();
      expect(changes, 0);
    },
  );

  test(
    'password switch starts a new sync while old discovery is pending',
    () async {
      final entered = Completer<void>();
      final oldResponse = Completer<List<WebDavLibraryEntry>>();
      final ops = _Ops()
        ..read = (config, path) async {
          if (config.pass == 'old') {
            if (!entered.isCompleted) entered.complete();
            return oldResponse.future;
          }
          if (path == '/comics/') {
            return [const WebDavLibraryEntry(name: 'New', isDirectory: true)];
          }
          return _Ops.pages;
        };
      final library = create(ops);
      final pending = library.source.synchronizer.synchronize();
      await entered.future;
      final previous = settings.connection;
      settings = configuration('new');
      library.source.onConfigurationChanged(previous);
      expect((await library.source.synchronizer.synchronize()).success, isTrue);
      final version = library.source.contentVersion.value;
      final status = library.source.synchronizer.status.value;
      oldResponse.complete([
        const WebDavLibraryEntry(name: 'Old', isDirectory: true),
      ]);
      expect((await pending).error, isTrue);
      expect(library.source.synchronizer.status.value, same(status));
      expect(library.source.contentVersion.value, version);
      expect(library.cache.all(settings.connection.cacheKey).keys, ['New']);
    },
  );

  test(
    'late snapshot cannot overwrite new content sharing the same cache key',
    () async {
      final entered = Completer<void>();
      final oldResponse = Completer<List<WebDavLibraryEntry>>();
      final ops = _Ops()
        ..read = (config, _) {
          if (config.pass == 'old') {
            if (!entered.isCompleted) entered.complete();
            return oldResponse.future;
          }
          return Future.value([
            const WebDavLibraryEntry(name: 'new.jpg', isDirectory: false),
          ]);
        };
      final library = create(ops);
      final pending = library.source.loadComicInfo('Book');
      await entered.future;
      // Simulate an imported setting: no save callback was emitted.
      settings = configuration('new');
      final current = await library.source.loadComicInfo('Book');
      expect(current.data.cover, '/comics/Book/new.jpg');
      oldResponse.complete(_Ops.pages);
      expect((await pending).error, isTrue);
      expect(
        library.cache.find(settings.connection.cacheKey, 'Book')!.cover,
        '/comics/Book/new.jpg',
      );
      expect(
        (await library.source.loadComicInfo('Book')).data.cover,
        '/comics/Book/new.jpg',
      );
    },
  );

  test(
    'configuration change cancels metadata fallback and chapter requests',
    () async {
      final entered = Completer<void>();
      final text = Completer<String>();
      final ops = _Ops();
      ops.read = (_, _) async => [
        ..._Ops.pages,
        const WebDavLibraryEntry(name: 'metadata.json', isDirectory: false),
      ];
      ops.readMetadata = (_, _) {
        entered.complete();
        return text.future;
      };
      final library = create(ops);
      final pending = library.source.loadComicInfo('Book');
      await entered.future;
      settings = configuration('new');
      text.complete('{}');
      expect((await pending).error, isTrue);
      expect(library.cache.find(settings.connection.cacheKey, 'Book'), isNull);
    },
  );

  test('late chapter listing is cancelled after disposal', () async {
    final response = Completer<List<WebDavLibraryEntry>>();
    final ops = _Ops()..read = (_, _) => response.future;
    final library = create(ops);
    final pending = library.source.loadComicPages('Book', 'Chapter');
    final closing = library.source.closeAndWait();
    response.complete(_Ops.pages);
    expect((await pending).error, isTrue);
    await closing;
  });

  test('schedule-only changes keep the active connection session', () async {
    final response = Completer<List<WebDavLibraryEntry>>();
    final ops = _Ops()..read = (_, _) => response.future;
    final library = create(ops);
    final pending = library.source.loadComicInfo('Book');
    settings = WebDavLibrarySettings(
      connection: settings.connection,
      autoSync: false,
      intervalMinutes: 15,
    );
    response.complete(_Ops.pages);
    expect((await pending).success, isTrue);
  });

  test(
    'close joins old configurations, direct requests and their finalizers',
    () async {
      final old = gate(_Ops.pages);
      final snapshot = gate(_Ops.pages);
      final chapter = gate(_Ops.pages);
      final discovery = gate(<WebDavLibraryEntry>[]);
      final connection = gate(true);
      final ops = _Ops()
        ..read = (config, path) {
          if (config.pass == 'old') return old.run();
          if (path == '/comics/') return discovery.run();
          if (path == '/comics/Book/Chapter/') return chapter.run();
          return snapshot.run();
        }
        ..checkConnection = (_) async {
          await connection.run();
        };
      final library = create(ops);
      library.cache.count('any');
      final oldInfo = library.source.loadComicInfo('Old');
      await old.entered.future;
      final previous = settings.connection;
      settings = configuration('new');
      library.source.onConfigurationChanged(previous);
      final newInfo = library.source.loadComicInfo('New');
      final pages = library.source.loadComicPages('Book', 'Chapter');
      final test = library.source.testConnection(settings.connection);
      final sync = library.source.synchronizer.synchronize();
      await Future.wait([
        snapshot.entered.future,
        chapter.entered.future,
        connection.entered.future,
        discovery.entered.future,
      ]);
      var closed = false;
      var changes = 0;
      library.source.contentVersion.addListener(() => changes++);
      final closing = library.source.closeAndWait();
      unawaited(closing.then((_) => closed = true));
      expect(library.source.closeAndWait(), same(closing));
      expect(library.source.isDisposed, isTrue);
      expect(ops.disposals, 1);
      expect(ops.cancellations, greaterThanOrEqualTo(1));
      snapshot.finish();
      chapter.finish();
      discovery.finish();
      old.response.complete(_Ops.pages);
      connection.response.complete(true);
      await Future.wait([
        old.enteredCleanup.future,
        connection.enteredCleanup.future,
      ]);
      await pumpEventQueue();
      expect(closed, isFalse);
      expect(library.cache.count('any'), 0);
      void finalObserver() {}
      library.source.contentVersion.addListener(finalObserver);
      library.source.contentVersion.removeListener(finalObserver);
      old.releaseCleanup.complete();
      await pumpEventQueue();
      expect(closed, isFalse);
      connection.releaseCleanup.complete();
      expect((await oldInfo).error, isTrue);
      expect((await newInfo).error, isTrue);
      expect((await pages).error, isTrue);
      expect((await test).error, isTrue);
      expect((await sync).error, isTrue);
      await closing;
      expect(changes, 0);
      expect(() => library.cache.count('any'), throwsStateError);
      expect(
        () => library.source.contentVersion.addListener(finalObserver),
        throwsFlutterError,
      );
      await File(library.cache.path).delete();
      expect(File(library.cache.path).existsSync(), isFalse);
    },
  );

  test(
    'all synchronous cleanup attempts run before close reports their failures',
    () async {
      final chapter = gate(_Ops.pages);
      final cancellationError = StateError('cancel transports failed');
      final disposalError = StateError('dispose transports failed');
      final ops = _Ops()
        ..read = ((_, _) => chapter.run())
        ..cancelError = cancellationError
        ..disposeError = disposalError;
      final library = create(ops);
      library.cache.count('any');
      final pages = library.source.loadComicPages('Book', 'Chapter');
      await chapter.entered.future;
      final closing = library.source.closeAndWait();
      var failed = false;
      final checked = expectLater(
        closing,
        throwsA(
          isA<WebDavLibraryLifecycleFailure>().having(
            (error) {
              failed = true;
              expectedCloseFailures[library.source] = error;
              return error.failures.map((failure) => failure.error);
            },
            'original cleanup errors',
            [same(cancellationError), same(disposalError)],
          ),
        ),
      );
      expect(ops.cancellations, 1);
      expect(ops.disposals, 1);
      chapter.response.completeError(StateError('cancelled chapter response'));
      await chapter.enteredCleanup.future;
      await pumpEventQueue();
      expect(failed, isFalse);
      expect(library.cache.count('any'), 0);
      chapter.releaseCleanup.complete();
      expect((await pages).error, isTrue);
      await checked;
      expect(() => library.cache.count('any'), throwsStateError);
      expect(library.source.closeAndWait(), same(closing));
    },
  );

  test(
    'preparation freezes public calls and joins direct connection and chapter cleanup',
    () async {
      final chapter = gate(_Ops.pages);
      final connection = gate(true);
      final ops = _Ops()
        ..read = ((_, _) => chapter.run())
        ..checkConnection = (_) async {
          await connection.run();
        };
      final library = create(ops);
      library.cache.count('any');
      final pages = library.source.loadComicPages('Book', 'Chapter');
      final test = library.source.testConnection(settings.connection);
      await Future.wait([chapter.entered.future, connection.entered.future]);
      final preparing = library.source.prepareForExit();
      expect(library.source.prepareForExit(), same(preparing));
      expect(library.source.isDisposed, isFalse);
      expect(ops.cancellations, 1);
      expect(ops.disposals, 0);
      await expectLater(library.source.loadComics(1), throwsStateError);
      await expectLater(
        library.source.loadComicInfo('Other'),
        throwsStateError,
      );
      await expectLater(
        library.source.loadComicPages('Other', 'Chapter'),
        throwsStateError,
      );
      await expectLater(
        library.source.getImageLoadingConfig('/001.jpg', 'Book', 'Chapter'),
        throwsStateError,
      );
      expect(
        () => library.source.getThumbnailLoadingConfig('/001.jpg'),
        throwsStateError,
      );
      expect(
        (await library.source.testConnection(settings.connection)).error,
        isTrue,
      );
      expect(ops.tests, 1);
      expect(ops.calls, hasLength(1));
      var ready = false;
      unawaited(preparing.then((_) => ready = true));
      chapter.finish();
      connection.response.complete(true);
      await connection.enteredCleanup.future;
      await pumpEventQueue();
      expect(ready, isFalse);
      expect(library.cache.count('any'), 0);
      connection.releaseCleanup.complete();
      expect((await pages).error, isTrue);
      expect((await test).error, isTrue);
      final release = await preparing;
      expect(library.source.isDisposed, isFalse);
      expect(ops.disposals, 0);
      ops.read = (_, _) async => _Ops.pages;
      ops.checkConnection = (_) async {};
      release();
      release();
      expect((await library.source.loadComicInfo('Fresh')).success, isTrue);
      expect(
        (await library.source.testConnection(settings.connection)).success,
        isTrue,
      );
    },
  );

  test(
    'failed preparation drains all requests before restoring admission',
    () async {
      final snapshot = gate(_Ops.pages);
      final chapter = gate(_Ops.pages);
      final cancellationError = StateError('cancel hook failed');
      final ops = _Ops()
        ..read = ((_, path) =>
            path.endsWith('/Chapter/') ? chapter.run() : snapshot.run())
        ..cancelError = cancellationError;
      final library = create(ops);
      final info = library.source.loadComicInfo('Book');
      final pages = library.source.loadComicPages('Book', 'Chapter');
      await Future.wait([snapshot.entered.future, chapter.entered.future]);
      final preparing = library.source.prepareForExit();
      expect(library.source.prepareForExit(), same(preparing));
      var failed = false;
      final checked = expectLater(
        preparing,
        throwsA(
          isA<WebDavLibraryLifecycleFailure>().having(
            (error) {
              failed = true;
              return error.failures.map((failure) => failure.error);
            },
            'preparation cleanup error',
            [same(cancellationError)],
          ),
        ),
      );
      ops.cancelError = null;
      snapshot.finish();
      chapter.response.complete(_Ops.pages);
      await chapter.enteredCleanup.future;
      await pumpEventQueue();
      expect(failed, isFalse);
      await expectLater(
        library.source.loadComicInfo('Blocked'),
        throwsStateError,
      );
      expect(ops.disposals, 0);
      chapter.releaseCleanup.complete();
      expect((await info).error, isTrue);
      expect((await pages).error, isTrue);
      await checked;
      ops.read = (_, _) async => _Ops.pages;
      expect(library.source.isDisposed, isFalse);
      expect((await library.source.loadComicInfo('Fresh')).success, isTrue);
      final release = await library.source.prepareForExit();
      release();
      expect((await library.source.loadComicInfo('Fresh')).success, isTrue);
    },
  );

  test(
    'business request failures do not become preparation failures',
    () async {
      final chapter = gate(_Ops.pages);
      final connection = gate(true);
      final ops = _Ops()
        ..read = ((_, _) => chapter.run())
        ..checkConnection = (_) async {
          await connection.run();
        };
      final library = create(ops);
      final pages = library.source.loadComicPages('Book', 'Chapter');
      final test = library.source.testConnection(settings.connection);
      await Future.wait([chapter.entered.future, connection.entered.future]);
      final preparing = library.source.prepareForExit();
      chapter.response.completeError(StateError('chapter network failed'));
      connection.response.completeError(StateError('test connection failed'));
      chapter.releaseCleanup.complete();
      connection.releaseCleanup.complete();
      expect((await pages).error, isTrue);
      expect((await test).error, isTrue);
      final release = await preparing;
      release();
      ops.read = (_, _) async => _Ops.pages;
      ops.checkConnection = (_) async {};
      expect(
        (await library.source.loadComicPages('Book', 'Chapter')).success,
        isTrue,
      );
      expect(
        (await library.source.testConnection(settings.connection)).success,
        isTrue,
      );
    },
  );

  test('old releases cannot lift a later preparation', () async {
    final library = create(_Ops());
    final first = await library.source.prepareForExit();
    first();
    final second = await library.source.prepareForExit();
    first();
    await expectLater(library.source.loadComicInfo('Book'), throwsStateError);
    second();
    second();
    expect((await library.source.loadComicInfo('Book')).success, isTrue);
  });

  for (final close in [false, true]) {
    test(
      'transport drain finishes before storage release; close=$close',
      () async {
        final native = gate(true);
        final ops = _Ops()
          ..drain = () async {
            await native.run();
          };
        final library = create(ops);
        library.cache.count('any');
        var finished = false;
        final pending = close
            ? library.source.closeAndWait().then((_) => () {})
            : library.source.prepareForExit();
        unawaited(pending.then((_) => finished = true));
        await native.entered.future;
        await pumpEventQueue();
        expect(finished, isFalse);
        expect(library.cache.count('any'), 0);
        native.finish();
        final release = await pending;
        ops.drain = () async {};
        if (close) {
          expect(() => library.cache.count('any'), throwsStateError);
        } else {
          release();
          expect((await library.source.loadComicInfo('Fresh')).success, isTrue);
        }
      },
    );
  }

  test(
    'close during preparation joins existing work and invalidates stale release',
    () async {
      final chapter = gate(_Ops.pages);
      final connection = gate(true);
      final ops = _Ops()
        ..read = ((_, _) => chapter.run())
        ..checkConnection = (_) async {
          await connection.run();
        };
      final library = create(ops);
      final pages = library.source.loadComicPages('Book', 'Chapter');
      final test = library.source.testConnection(settings.connection);
      await Future.wait([chapter.entered.future, connection.entered.future]);
      final preparing = library.source.prepareForExit();
      final closing = library.source.closeAndWait();
      var closed = false;
      unawaited(closing.then((_) => closed = true));
      expect(library.source.isDisposed, isTrue);
      expect(ops.disposals, 1);
      chapter.finish();
      await pumpEventQueue();
      expect(closed, isFalse);
      connection.finish();
      expect((await pages).error, isTrue);
      expect((await test).error, isTrue);
      final release = await preparing;
      await closing;
      release();
      release();
      await expectLater(library.source.loadComicInfo('Book'), throwsStateError);
      await expectLater(library.source.prepareForExit(), throwsStateError);
      expect(
        (await library.source.testConnection(settings.connection)).error,
        isTrue,
      );
      expect(ops.calls, hasLength(1));
      expect(ops.tests, 1);
      expect(() => library.cache.count('any'), throwsStateError);
    },
  );
}

class _Gate<T> {
  _Gate(this.fallback);

  final T fallback;
  final entered = Completer<void>();
  final response = Completer<T>();
  final enteredCleanup = Completer<void>();
  final releaseCleanup = Completer<void>();

  Future<T> run() async {
    entered.complete();
    try {
      return await response.future;
    } finally {
      enteredCleanup.complete();
      await releaseCleanup.future;
    }
  }

  void finish() {
    if (!response.isCompleted) response.complete(fallback);
    if (!releaseCleanup.isCompleted) releaseCleanup.complete();
  }
}

class _Ops extends WebDavLibraryOps {
  static const pages = [
    WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
  ];
  final calls = <String>[];
  int disposals = 0;
  int cancellations = 0;
  int tests = 0;
  Object? disposeError;
  Object? cancelError;
  void Function()? onCancel;
  Future<List<WebDavLibraryEntry>> Function(WebDavLibraryConfig, String) read =
      (_, _) async => pages;
  Future<String> Function(WebDavLibraryConfig, String) readMetadata =
      (_, _) async => '{}';
  Future<void> Function(WebDavLibraryConfig) checkConnection = (_) async {};
  Future<void> Function() drain = () async {};

  @override
  Future<void> drainPending() => drain();

  @override
  void cancelPending() {
    cancellations++;
    onCancel?.call();
    final error = cancelError;
    if (error != null) throw error;
  }

  @override
  void dispose() {
    disposals++;
    final error = disposeError;
    if (error != null) throw error;
  }

  @override
  Future<List<WebDavLibraryEntry>> readDir(
    WebDavLibraryConfig config,
    String path,
  ) {
    calls.add(path);
    return read(config, path);
  }

  @override
  Future<String> readText(WebDavLibraryConfig config, String path) =>
      readMetadata(config, path);

  @override
  Future<void> test(WebDavLibraryConfig config) {
    tests++;
    return checkConnection(config);
  }
}
