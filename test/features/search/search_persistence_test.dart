import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/search/search_shortcut.dart';
import 'package:venera_next/features/search/search_shortcut_manager.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';

void main() {
  test(
    'shortcut commands wait for admission and merge concurrent additions',
    () async {
      final root = Directory.systemTemp.createTempSync('search-persistence-');
      App.dataPath = root.path;
      final previous = appdata.settings['searchShortcuts'];
      appdata.settings['searchShortcuts'] = <dynamic>[];
      addTearDown(() {
        appdata.settings['searchShortcuts'] = previous;
        root.deleteSync(recursive: true);
      });
      const first = SearchShortcut(
        kind: SearchShortcutKind.tag,
        sourceKey: 'source',
        namespace: 'tag',
        value: 'first',
      );
      const second = SearchShortcut(
        kind: SearchShortcutKind.author,
        sourceKey: 'source',
        namespace: 'author',
        value: 'second',
      );
      final manager = SearchShortcutManager.instance;
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      final adding = [
        manager.add(first),
        manager.add(second),
        manager.add(first),
      ];
      await Future<void>.delayed(Duration.zero);
      expect(manager.all, isEmpty);
      release.complete();
      await Future.wait([exclusive, ...adding]);
      expect(manager.all.map((item) => item.identity), [
        first.identity,
        second.identity,
      ]);
      await manager.remove(first);
      final stored = jsonDecode(
        File('${root.path}/appdata.json').readAsStringSync(),
      );
      expect(stored['settings']['searchShortcuts'], [second.toJson()]);
    },
  );
}
