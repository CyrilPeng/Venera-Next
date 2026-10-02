import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/webdav_library/webdav_library.dart';

void main() {
  late Directory directory;
  late List<WebDavLibrarySource> sources;
  late WebDavLibrarySettings settings;

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
    settings = configuration('old');
  });

  tearDown(() {
    for (final source in sources) {
      source.dispose();
    }
    directory.deleteSync(recursive: true);
  });

  test(
    'transport disposal failure still closes storage and rejects new work',
    () {
      final ops = _Ops()..disposeError = StateError('transport close failed');
      final library = create(ops);
      library.cache.count('any');
      expect(library.source.dispose, throwsStateError);
      expect(library.source.isDisposed, isTrue);
      expect(() => library.cache.count('any'), throwsStateError);
      library.source.dispose();
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
      first.source.dispose();
      expect(firstOps.disposals, 1);
      expect(secondOps.disposals, 0);
      blocked.complete(_Ops.pages);
      expect((await pending).error, isTrue);
      expect((await second.source.loadComicInfo('Book')).success, isTrue);
    },
  );

  test(
    'dispose before scheduled sync starts resolves without opening storage',
    () async {
      final ops = _Ops();
      final library = create(ops);
      final pending = library.source.synchronizer.synchronize();
      library.source.dispose();
      expect((await pending).error, isTrue);
      expect(ops.calls, isEmpty);
      expect(File(library.cache.path).existsSync(), isFalse);
      library.source.dispose();
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
      library.source.dispose();
      response.complete([
        const WebDavLibraryEntry(name: 'Old', isDirectory: true),
      ]);
      expect((await pending).error, isTrue);
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
    library.source.dispose();
    response.complete(_Ops.pages);
    expect((await pending).error, isTrue);
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
}

class _Ops extends WebDavLibraryOps {
  static const pages = [
    WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
  ];
  final calls = <String>[];
  int disposals = 0;
  Object? disposeError;
  Future<List<WebDavLibraryEntry>> Function(WebDavLibraryConfig, String) read =
      (_, _) async => pages;
  Future<String> Function(WebDavLibraryConfig, String) readMetadata =
      (_, _) async => '{}';

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
  Future<void> test(WebDavLibraryConfig config) async {}
}
