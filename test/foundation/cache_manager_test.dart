import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/cache_manager.dart';

bool _sqliteAvailable() {
  try {
    final db = sqlite3.openInMemory();
    db.dispose();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  test(
    'checkCache resets checking flag after failure',
    () async {
      final dataDir = Directory.systemTemp.createTempSync('venera-cache-data-');
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-cache-cache-',
      );
      addTearDown(() {
        CacheManager.resetForTesting();
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      CacheManager.debugDisableInitialScan = true;

      final manager = CacheManager();
      var checkCount = 0;
      CacheManager.debugOnCheckCacheStart = () {
        checkCount++;
        if (checkCount == 1) {
          throw StateError('forced cache check failure');
        }
      };

      await expectLater(manager.checkCache(), throwsA(isA<StateError>()));

      await manager.checkCache();

      expect(checkCount, 2);
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'initial scan failure falls back to tracked cache size',
    () async {
      final dataDir = Directory.systemTemp.createTempSync('venera-cache-data-');
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-cache-cache-',
      );
      addTearDown(() {
        CacheManager.resetForTesting();
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      CacheManager.debugScanDirOverride = (dbPath, dir) {
        throw StateError('forced scan failure');
      };

      final manager = CacheManager();
      await manager.debugInitialScanTask;

      await manager.writeCache('key', [1, 2, 3]);

      expect(manager.currentSize, 3);
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );
}
