import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/comic_source/source_transaction_journal.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/sync/app_data_transfer.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/selection_operation.dart';

Map<String, dynamic> _settings(Archive archive) =>
    (jsonDecode(utf8.decode(archive.findFile('appdata.json')!.content))
            as Map<String, dynamic>)['settings']
        as Map<String, dynamic>;

void main() {
  test(
    'export awaits accepted history and stages current filtered settings',
    () async {
      final root = Directory.systemTemp.createTempSync('app-data-snapshot-');
      final previous = {
        for (final key in [
          'followUpdatesFolder',
          'quickFavorite',
          'disableSyncFields',
          'language',
        ])
          key: appdata.settings[key],
      };
      final favorites = LocalFavoritesManager();
      final history = HistoryManager();
      try {
        App.dataPath = (Directory('${root.path}/data')..createSync()).path;
        App.cachePath = (Directory('${root.path}/cache')..createSync()).path;
        Directory('${App.dataPath}/comic_source').createSync();
        File(
          '${App.dataPath}/comic_source/example.js',
        ).writeAsStringSync('// source');
        final cookies = sqlite3.open('${App.dataPath}/cookie.db');
        cookies.execute('CREATE TABLE cookie (value TEXT);');
        cookies.dispose();
        await favorites.init();
        await history.init();
        final write = history.addHistory(
          History(
            type: ComicType.local,
            time: DateTime.now(),
            title: 'queued',
            subtitle: '',
            cover: '',
            ep: 1,
            page: 7,
            id: 'queued',
            readEpisode: {'1'},
            maxPage: 10,
            readDurationMs: 0,
          ),
        );
        appdata.settings['language'] = 'zh-CN';
        appdata.settings['disableSyncFields'] = 'language';
        final pending = await SourceTransactionJournal.begin(
          dataPath: App.dataPath,
          script: File('${App.dataPath}/comic_source/example.js'),
          before: utf8.encode('// source'),
          after: utf8.encode('// changed'),
        );
        await pending.close();
        await expectLater(exportAppData(sync: false), throwsStateError);
        await SourceTransactionJournal.recover(App.dataPath);
        final committed = await SourceTransactionJournal.begin(
          dataPath: App.dataPath,
          script: File('${App.dataPath}/comic_source/example.js'),
          before: utf8.encode('// source'),
          after: utf8.encode('// source'),
        );
        committed.commit();
        final residue = committed.directory;
        await committed.close();
        final complete = ZipDecoder().decodeBytes(
          (await exportAppData(sync: false)).readAsBytesSync(),
        );
        await write;
        expect(residue.existsSync(), isFalse);
        expect(
          complete.files.any(
            (entry) => entry.name.contains('.source-transactions'),
          ),
          isFalse,
        );
        expect(_settings(complete)['language'], 'zh-CN');
        expect(
          utf8.decode(complete.findFile('comic_source/example.js')!.content),
          '// source',
        );
        final exportedPath = '${root.path}/history.db';
        File(
          exportedPath,
        ).writeAsBytesSync(complete.findFile('history.db')!.content);
        final exported = sqlite3.open(exportedPath);
        try {
          expect(
            exported.select('SELECT page FROM history WHERE id = ?;', [
              'queued',
            ]).single['page'],
            7,
          );
          expect(
            exported.select('PRAGMA integrity_check;').single.values.single,
            'ok',
          );
        } finally {
          exported.dispose();
        }
        final filtered = ZipDecoder().decodeBytes(
          (await exportAppData()).readAsBytesSync(),
        );
        expect(_settings(filtered).containsKey('language'), isFalse);
        // A prior filtered syncdata.json must not leak into a now-unfiltered export.
        appdata.settings['disableSyncFields'] = '';
        appdata.settings['language'] = 'en-US';
        final unfiltered = ZipDecoder().decodeBytes(
          (await exportAppData()).readAsBytesSync(),
        );
        expect(_settings(unfiltered)['language'], 'en-US');
        final saveOwner = SelectionOperation();
        var generations = 0;
        var saves = 0;
        late File unknown;
        late File generated;
        final saving = saveOwner.run(
          (operation) => operation.useTemporaryFile(
            cacheDirectory: Directory(App.cachePath),
            filename: 'data.venera',
            prepare: (file) async {
              generations++;
              generated = await exportAppData(sync: false, destination: file);
              expect(generated.path, file.path);
              expect(
                Directory('${file.parent.path}/export-staging').existsSync(),
                isFalse,
              );
            },
            consume: (file) async {
              saves++;
              final archive = ZipDecoder().decodeBytes(file.readAsBytesSync());
              expect(_settings(archive)['language'], 'en-US');
              expect(archive.findFile('history.db'), isNotNull);
              unknown = File('${file.parent.parent.path}/unknown')
                ..writeAsStringSync('keep');
            },
          ),
        );
        await expectLater(saving, throwsA(isA<SelectionCleanupFailure>()));
        expect(generated.existsSync(), isTrue);
        await expectLater(
          saveOwner.closeAndWait(),
          throwsA(isA<SelectionCleanupFailure>()),
        );
        unknown.deleteSync();
        await saveOwner.closeAndWait();
        expect(generated.existsSync(), isFalse);
        expect([generations, saves], [1, 1]);
        final owned = Directory('${App.dataPath}/owned-upload')..createSync();
        final destination = File('${owned.path}/snapshot.venera');
        appdata.settings['disableSyncFields'] = 'language';
        await exportSyncAppData(excludeFields: true, destination: destination);
        final ownedArchive = ZipDecoder().decodeBytes(
          destination.readAsBytesSync(),
        );
        expect(_settings(ownedArchive).containsKey('language'), isFalse);
        expect(ownedArchive.findFile('history.db'), isNotNull);
        expect(owned.listSync(), hasLength(1));
        expect(
          FileSystemEntity.identicalSync(
            owned.listSync().single.path,
            destination.path,
          ),
          isTrue,
        );
        File(
          '${App.dataPath}/cookie.db',
        ).writeAsBytesSync(List.filled(4096, 42));
        await expectLater(exportAppData(), throwsA(isA<SqliteException>()));
        final remaining = Directory(App.cachePath).listSync();
        expect(
          remaining.where((entry) => entry.path.contains('.app_data_export_')),
          isEmpty,
        );
        expect(
          remaining.where((entry) => entry.path.endsWith('.venera')),
          hasLength(3),
        );
      } finally {
        await history.waitForAsyncWrites();
        if (history.isInitialized) history.close();
        await favorites.closeAndWait();
        await appdata.saveData(false);
        for (final entry in previous.entries) {
          appdata.settings[entry.key] = entry.value;
        }
        root.deleteSync(recursive: true);
      }
    },
  );
}
