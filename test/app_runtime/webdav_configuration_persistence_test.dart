import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/webdav_library.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/webdav_library/webdav_library_api.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/persistence_failure.dart';
import 'package:venera_next/foundation/sqlite_connection.dart';

WebDavLibrarySettings _config(String host, {bool auto = false}) =>
    WebDavLibrarySettings(
      connection: WebDavLibraryConfig(
        url: 'https://$host.example',
        user: '',
        pass: '',
        remotePath: '/books/',
      ),
      autoSync: auto,
      intervalMinutes: 60,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  App.dataPath = Directory.systemTemp.path;
  late Directory root;
  late String oldPath;
  late Map oldSettings;
  late ComicSourceManager manager;
  late WebDavLibraryServices services;
  late WebDavLibraryCache cache;
  setUp(() {
    root = Directory.systemTemp.createTempSync('webdav-config-');
    oldPath = App.dataPath;
    oldSettings = jsonDecode(jsonEncode(appdata.toJson()['settings'])) as Map;
    App.dataPath = root.path;
    appdata.settings['disableSyncFields'] = '';
    _config(
      'a',
    ).toSettings().forEach((key, value) => appdata.settings[key] = value);
    appdata.settings['explore_pages'] = [
      'Other',
      WebDavLibrarySource.explorePageTitle,
    ];
    manager = ComicSourceManager();
    services = createWebDavLibraryServices(
      dataPath: root.path,
      manager: manager,
      ops: _Ops(),
    );
    cache = WebDavLibraryCache('${root.path}/webdav_library.db');
    cache.setLastSuccessfulSync(_config('a').connection.cacheKey, 123);
  });
  tearDown(() async {
    await services.source.closeAndWait();
    cache.dispose();
    await manager.closeAndWait();
    oldSettings.forEach((key, value) => appdata.settings[key] = value);
    App.dataPath = oldPath;
    root.deleteSync(recursive: true);
  });

  test(
    'admitted configuration merges pages and invalidates only changed connection',
    () async {
      final gate = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => gate.future);
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final prior = appdata.updateSettings(
        (draft) => draft['explore_pages'] = ['Later'],
      );
      final saving = services.settings.save(_config('b'));
      expect(services.settings.read().connection.url, 'https://a.example');
      expect(manager.find(WebDavLibrarySource.sourceKey), isNull);
      gate.complete();
      await Future.wait([exclusive, prior, saving]);
      expect(appdata.settings['explore_pages'], [
        'Later',
        WebDavLibrarySource.explorePageTitle,
      ]);
      expect(cache.lastSuccessfulSync(_config('a').connection.cacheKey), 0);
      expect(manager.find(WebDavLibrarySource.sourceKey), isNotNull);
      cache.setLastSuccessfulSync(_config('b').connection.cacheKey, 456);
      await services.settings.save(_config('b', auto: true));
      expect(cache.lastSuccessfulSync(_config('b').connection.cacheKey), 456);
      final saved =
          jsonDecode(File('${root.path}/appdata.json').readAsStringSync())
              as Map;
      expect(saved['settings']['webdavComicLibraryAutoSync'], isTrue);
    },
  );

  test(
    'storage failure retains applied configuration and retries without restoring old data',
    () async {
      final blocker = Directory('${root.path}/appdata.json')..createSync();
      await expectLater(
        services.settings.save(_config('b')),
        throwsA(
          isA<PersistenceFailure>().having(
            (e) => e.commitState,
            'state',
            PersistenceCommitState.unknown,
          ),
        ),
      );
      expect(services.settings.read().connection.url, 'https://b.example');
      expect(cache.lastSuccessfulSync(_config('a').connection.cacheKey), 0);
      expect(manager.find(WebDavLibrarySource.sourceKey), isNotNull);
      blocker.deleteSync();
      await services.settings.save(_config('b'));
      expect(File('${root.path}/appdata.json').existsSync(), isTrue);
    },
  );

  test(
    'post-save cache failure remains retryable with original invalidation',
    () async {
      final db = openSqliteDatabase('${root.path}/webdav_library.db');
      addTearDown(db.dispose);
      db.execute(
        "CREATE TRIGGER reject_clear BEFORE DELETE ON webdav_library_state BEGIN SELECT RAISE(ABORT, 'injected invalidation'); END",
      );
      await expectLater(
        services.settings.save(_config('b')),
        throwsA(
          isA<PersistenceFailure>().having(
            (e) => e.commitState,
            'state',
            PersistenceCommitState.committed,
          ),
        ),
      );
      expect(cache.lastSuccessfulSync(_config('a').connection.cacheKey), 123);
      db.execute('DROP TRIGGER reject_clear');
      await services.settings.save(_config('b'));
      expect(cache.lastSuccessfulSync(_config('a').connection.cacheKey), 0);
    },
  );

  test(
    'two admitted saves publish in order and disabling removes only library entries',
    () async {
      final first = services.settings.save(_config('b'));
      final second = services.settings.save(
        WebDavLibrarySettings.read((_) => null),
      );
      await Future.wait([first, second]);
      expect(services.settings.read().connection.isValid, isFalse);
      expect(manager.find(WebDavLibrarySource.sourceKey), isNull);
      expect(appdata.settings['explore_pages'], ['Other']);
    },
  );

  test(
    'retired source rejects a queued save before touching settings or registry',
    () async {
      final gate = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => gate.future);
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final saving = services.settings.save(_config('b'));
      final rejected = expectLater(saving, throwsStateError);
      await services.source.closeAndWait();
      gate.complete();
      await Future.wait([exclusive, rejected]);
      expect(services.settings.read().connection.url, 'https://a.example');
      expect(manager.find(WebDavLibrarySource.sourceKey), isNull);
    },
  );

  test(
    'replacement registry owner rejects the old queued configuration',
    () async {
      final gate = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => gate.future);
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final saving = services.settings.save(_config('b'));
      final rejected = expectLater(saving, throwsStateError);
      final next = createWebDavLibraryServices(
        dataPath: root.path,
        manager: manager,
        ops: _Ops(),
      );
      addTearDown(next.source.closeAndWait);
      mountWebDavLibrary(next);
      final adapter = manager.find(WebDavLibrarySource.sourceKey);
      gate.complete();
      await Future.wait([exclusive, rejected]);
      expect(services.settings.read().connection.url, 'https://a.example');
      expect(manager.find(WebDavLibrarySource.sourceKey), same(adapter));
      await services.source.closeAndWait();
      mountWebDavLibrary(services);
      expect(manager.find(WebDavLibrarySource.sourceKey), same(adapter));
    },
  );
}

class _Ops extends WebDavLibraryOps {
  @override
  Future<void> test(WebDavLibraryConfig config) async {}
  @override
  Future<List<WebDavLibraryEntry>> readDir(
    WebDavLibraryConfig config,
    String remotePath,
  ) async => [];
  @override
  Future<String> readText(
    WebDavLibraryConfig config,
    String remotePath,
  ) async => '{}';
}
