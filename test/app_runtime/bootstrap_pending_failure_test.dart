import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/app_runtime/bootstrap_core.dart';
import 'package:venera_next/app_runtime/headless_bindings.dart';
import 'package:venera_next/features/sync/data_sync_ownership.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/js_engine.dart';

import '../support/native_test_environment.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'reports a store startup failure before joining a pending source init',
    () async {
      final root = Directory.systemTemp.createTempSync('startup-pending-init-');
      final native = windowsNativeTestDirectory.absolute.path;
      DynamicLibrary.open('$native/flutter_windows.dll');
      DynamicLibrary.open('$native/flutter_qjs_plugin.dll');
      final sources = Directory('${root.path}/comic_source')..createSync();
      File('${sources.path}/pending.js').writeAsStringSync('''
        class PendingSource extends ComicSource {
          key = 'pending_startup'; name = 'Pending startup'; version = '1.0.0';
          minAppVersion = '1.0.0';
          async init() {
            await new Promise(resolve => { globalThis.finishPendingInit = resolve; });
          }
          comic = {loadInfo: async () => ({title: 'Fixture', cover: '', tags: {}}),
                   loadEp: async () => []};
        }
      ''');
      File(
        '${root.path}/local.db',
      ).writeAsStringSync('invalid sqlite database');
      configureHeadlessBindings();
      final reported = Completer<Object>();
      final core = createCoreBootstrap(
        onDataChanged: () {},
        onStartupFailure: (phase, error, stack) {
          expect(phase, 'stores');
          expect(stack.toString(), isNotEmpty);
          reported.complete(error);
        },
        environment: () async {
          App.dataPath = root.path;
          App.cachePath = (Directory('${root.path}/cache')..createSync()).path;
          App.version = '1.18.0';
          App.isInitialized = true;
        },
      );
      final engine = JsEngine();
      final starting = core.start();
      var settled = false;
      final checked = expectLater(
        starting,
        throwsA(isA<SqliteException>()),
      ).whenComplete(() => settled = true);
      final ownership = SqliteDataSyncOwnership.applicationData(
        () => root.path,
      );
      try {
        final error = await reported.future.timeout(
          const Duration(seconds: 10),
        );
        expect(error, isA<SqliteException>());
        expect(
          engine.runCode('typeof finishPendingInit === "function"'),
          isTrue,
        );
        expect(settled, isFalse);
        expect(ownership.acquire, throwsA(isA<SqliteException>()));
      } finally {
        if (engine.runCode('typeof finishPendingInit === "function"') == true) {
          engine.runCode('void finishPendingInit()');
        }
        await checked;
        await core.close();
        ownership.acquire();
        ownership.release();
        expect(() => engine.runCode('1'), throwsStateError);
        await root.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );
}
