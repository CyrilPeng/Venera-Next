import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';

History _history(String id) {
  return History.fromMap({
    'type': ComicType.local.value,
    'time': DateTime(2026, 1, 1).millisecondsSinceEpoch,
    'title': 'Title $id',
    'subtitle': 'Author',
    'cover': 'cover.jpg',
    'ep': 1,
    'page': 2,
    'id': id,
    'readEpisode': ['1'],
    'max_page': 10,
  });
}

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
    'addHistoryAsync writes through an isolate-owned sqlite connection',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-history-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-history-cache-',
      );
      addTearDown(() {
        try {
          HistoryManager().close();
        } catch (_) {
          // ignore cleanup failures in partially initialized tests
        }
        HistoryManager.cache = null;
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      HistoryManager.cache = null;

      final manager = HistoryManager();
      await manager.init();

      await manager.addHistoryAsync(_history('comic-1'));

      final saved = manager.find('comic-1', ComicType.local);
      expect(saved, isNotNull);
      expect(saved!.page, 2);
      expect(saved.maxPage, 10);
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );
}
