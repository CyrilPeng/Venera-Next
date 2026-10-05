import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/app_runtime/bootstrap_core.dart';
import 'package:venera_next/app_runtime/headless_bindings.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/favorites/favorites_repository.dart';
import 'package:venera_next/features/sync/app_data_import_journal.dart';
import 'package:venera_next/features/sync/data_sync_commit.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/init.dart';
import 'package:venera_next/network/cookie_jar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'core recovers interrupted import before settings and databases open',
    () async {
      final root = Directory.systemTemp.createTempSync('bootstrap-import-');
      final data = Directory('${root.path}/data')..createSync();
      final cache = Directory('${root.path}/cache')..createSync();
      final native = Directory(
        'build/windows/x64/runner/Release',
      ).absolute.path;
      DynamicLibrary.open('$native/flutter_windows.dll');
      DynamicLibrary.open('$native/flutter_qjs_plugin.dll');
      final metadata = jsonEncode({
        'settings': {
          'dataVersion': 7,
          'deviceId': 'existing-device',
          'disableSyncFields': '',
        },
        'searchHistory': ['before-interruption'],
      });
      for (final name in [
        'appdata.json',
        'appdata.json.bak',
        'syncdata.json',
      ]) {
        File('${data.path}/$name').writeAsStringSync(metadata);
      }
      for (final name in ['history.db', 'local_favorite.db', 'cookie.db']) {
        final db = sqlite3.open('${data.path}/$name');
        if (name == 'local_favorite.db') {
          final favorites = FavoritesRepository(db);
          favorites.initializeMetadata();
          favorites.createFolder('original');
          favorites.addComic(
            'original',
            FavoriteItem(
              id: 'old snapshot',
              name: 'Old comic',
              author: '',
              coverPath: '',
              type: ComicType.local,
              tags: [],
            ),
            translatedTags: '',
            append: true,
          );
        } else {
          db.execute('CREATE TABLE recovery_marker (value TEXT)');
          db.execute("INSERT INTO recovery_marker VALUES ('old snapshot')");
        }
        db.dispose();
      }
      Directory('${data.path}/comic_source').createSync();
      File('${data.path}/comic_source/.keep').writeAsStringSync('old source');
      final journal = AppDataImportJournal.open(data.path);
      final transaction = await journal.prepare(
        resources: {
          'history.db',
          'local_favorite.db',
          'cookie.db',
          'comic_source',
        },
        syncOperationId: '11111111-1111-4111-8111-111111111111',
      );
      final invalid = File('${root.path}/invalid.db')
        ..writeAsBytesSync(List.filled(4096, 42));
      for (final name in ['history.db', 'local_favorite.db', 'cookie.db']) {
        await transaction.replaceFile(name, invalid);
      }
      final incoming = Directory('${root.path}/sources')..createSync();
      File('${incoming.path}/.keep').writeAsStringSync('partial new source');
      await transaction.replaceDirectory('comic_source', incoming);
      for (final name in [
        'appdata.json',
        'appdata.json.bak',
        'syncdata.json',
      ]) {
        await transaction.markChanging(name);
        File(
          '${data.path}/$name',
        ).writeAsStringSync('{broken incoming metadata');
      }
      final id = transaction.id;
      journal.close();
      expect(appdata.initializationState, InitializationState.notStarted);
      expect(SingleInstanceCookieJar.instance, isNull);

      final core = createCoreBootstrap(
        onDataChanged: () {},
        environment: () async {
          App.dataPath = data.path;
          App.cachePath = cache.path;
          App.version = '9.0.0';
          App.isInitialized = true;
        },
      );
      addTearDown(() async {
        await core.close();
        root.deleteSync(recursive: true);
      });
      configureHeadlessBindings();
      await core.start();
      expect(appdata.searchHistory, ['before-interruption']);
      expect(appdata.settings['dataVersion'], 7);
      expect(
        File('${data.path}/comic_source/.keep').readAsStringSync(),
        'old source',
      );
      for (final name in ['history.db', 'local_favorite.db', 'cookie.db']) {
        final db = sqlite3.open('${data.path}/$name');
        try {
          expect(
            name == 'local_favorite.db'
                ? FavoritesRepository(db).getFolderComics('original').single.id
                : db
                      .select('SELECT value FROM recovery_marker')
                      .single['value'],
            'old snapshot',
          );
        } finally {
          db.dispose();
        }
      }
      final recovered = AppDataImportJournal.open(data.path);
      try {
        final receipt = recovered.receipts.single;
        expect(receipt.id, id);
        expect(receipt.commitState, DataSyncCommitState.notApplied);
        expect(receipt.syncOperationId, '11111111-1111-4111-8111-111111111111');
        await recovered.acknowledge(id);
        expect(recovered.receipts, isEmpty);
      } finally {
        recovered.close();
      }
    },
    skip: !Platform.isWindows,
  );

  test(
    'unreadable recovery journal stops startup before appdata init',
    () async {
      final root = Directory.systemTemp.createTempSync('bootstrap-import-bad-');
      File(
        '${root.path}/.app-data-import.sqlite',
      ).writeAsBytesSync(List.filled(4096, 42));
      final oldState = appdata.initializationState;
      final oldCookies = SingleInstanceCookieJar.instance;
      final core = createCoreBootstrap(
        onDataChanged: () {},
        environment: () async {
          App.dataPath = root.path;
        },
      );
      try {
        await expectLater(core.start(), throwsA(isA<SqliteException>()));
        expect(appdata.initializationState, oldState);
        expect(SingleInstanceCookieJar.instance, same(oldCookies));
        expect(File('${root.path}/appdata.json').existsSync(), isFalse);
        expect(File('${root.path}/cookie.db').existsSync(), isFalse);
      } finally {
        await core.close();
        root.deleteSync(recursive: true);
      }
    },
  );
}
