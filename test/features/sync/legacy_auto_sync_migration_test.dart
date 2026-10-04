import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/core_bootstrap.dart';
import 'package:venera_next/features/sync/legacy_auto_sync_migration.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';

void main() {
  test(
    'real implicit save failure restores absent marker and permits retry',
    () async {
      final root = Directory.systemTemp.createTempSync('legacy-sync-');
      final previous = appdata.implicitData;
      App.dataPath = root.path;
      appdata.implicitData = {
        'unknown': {'keep': true},
      };
      final obstruction = Directory('${root.path}/implicitData.json.tmp')
        ..createSync();
      try {
        Future<void> migrate() => migrateLegacyAutoSync(
          implicitData: appdata.implicitData,
          webdav: ['server', 'user', 'password'],
          persist: appdata.writeImplicitData,
        );
        await expectLater(migrate(), throwsA(isA<FileSystemException>()));
        expect(appdata.implicitData.containsKey('webdavAutoSync'), isFalse);
        expect(appdata.implicitData['unknown'], {'keep': true});
        await obstruction.delete();
        await migrate();
        final saved = jsonDecode(
          await File('${root.path}/implicitData.json').readAsString(),
        );
        expect(saved, {
          'unknown': {'keep': true},
          'webdavAutoSync': true,
        });
        appdata.implicitData['second'] = 2;
        await appdata.writeImplicitData();
        expect(
          jsonDecode(
            await File('${root.path}/implicitData.json').readAsString(),
          )['second'],
          2,
        );
      } finally {
        appdata.implicitData = previous;
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'legacy tuple rule and existing explicit preferences are preserved',
    () async {
      for (final (config, expected) in <(Object?, bool)>[
        (null, false),
        (<Object>[], false),
        (['one'], false),
        (['a', 'b', 3], false),
        (['a', 'b', 'c', 'd'], false),
        ('not a tuple', false),
        (['', '', ''], true),
        (['server', 'user', 'password'], true),
      ]) {
        final implicit = <String, dynamic>{};
        var writes = 0;
        await migrateLegacyAutoSync(
          implicitData: implicit,
          webdav: config,
          persist: () async {
            writes++;
          },
        );
        expect(implicit['webdavAutoSync'], expected);
        expect(writes, 1);
        await migrateLegacyAutoSync(
          implicitData: implicit,
          webdav: ['x', 'y', 'z'],
          persist: () async =>
              fail('Existing preference must not be overwritten'),
        );
      }
    },
  );

  test(
    'failed save restores explicit null but preserves a newer preference',
    () async {
      final original = <String, dynamic>{'webdavAutoSync': null};
      await expectLater(
        migrateLegacyAutoSync(
          implicitData: original,
          webdav: null,
          persist: () async => throw StateError('save'),
        ),
        throwsStateError,
      );
      expect(original.containsKey('webdavAutoSync'), isTrue);
      expect(original['webdavAutoSync'], isNull);
      await expectLater(
        migrateLegacyAutoSync(
          implicitData: original,
          webdav: null,
          persist: () async {
            original['webdavAutoSync'] = true;
            throw StateError('save');
          },
        ),
        throwsStateError,
      );
      expect(original['webdavAutoSync'], isTrue);
    },
  );

  test(
    'startup waits for migration and rolls resources back on save failure',
    () async {
      final saving = Completer<void>();
      final entered = Completer<void>();
      var closed = false;
      var finished = false;
      final implicit = <String, dynamic>{};
      final core = CoreBootstrap(
        environment: () async {},
        settings: () async {},
        infrastructure: () async {},
        sources: () async {},
        stores: () async {},
        failureCleanup: [
          (
            name: 'store',
            close: () {
              closed = true;
            },
          ),
        ],
        finish: () async {
          await migrateLegacyAutoSync(
            implicitData: implicit,
            webdav: null,
            persist: () {
              entered.complete();
              return saving.future;
            },
          );
          finished = true;
        },
      );
      final result = core.start();
      final checked = expectLater(result, throwsStateError);
      await entered.future;
      expect(closed, isFalse);
      expect(finished, isFalse);
      saving.completeError(StateError('disk full'));
      await checked;
      expect(closed, isTrue);
      expect(finished, isFalse);
      expect(implicit, isEmpty);
    },
  );
}
