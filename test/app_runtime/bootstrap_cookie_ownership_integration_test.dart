import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:venera_next/app_runtime/bootstrap_core.dart';
import 'package:venera_next/app_runtime/headless_bindings.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/network/cookie_jar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real core closes its cookie jar but preserves a different database owner',
    () async {
      final root = Directory.systemTemp.createTempSync('venera-cookie-owner-');
      final otherRoot = Directory.systemTemp.createTempSync(
        'venera-other-cookie-',
      );
      final native = Directory(
        'build/windows/x64/runner/Release',
      ).absolute.path;
      DynamicLibrary.open('$native/flutter_windows.dll');
      DynamicLibrary.open('$native/flutter_qjs_plugin.dll');
      final core = createCoreBootstrap(
        onDataChanged: () {},
        environment: () async {
          App.dataPath = root.path;
          App.cachePath = (Directory('${root.path}/temp')..createSync()).path;
          App.version = '9.0.0';
          App.isInitialized = true;
        },
      );
      SingleInstanceCookieJar? otherCookies;
      addTearDown(() async {
        try {
          await core.close();
        } finally {
          otherCookies?.dispose();
          if (await root.exists()) await root.delete(recursive: true);
          if (await otherRoot.exists()) await otherRoot.delete(recursive: true);
        }
      });

      configureHeadlessBindings();
      await core.start();
      final ownedCookies = SingleInstanceCookieJar.instance!;
      final uri = Uri.parse('https://ownership.example.test/path');
      ownedCookies.saveFromResponse(uri, [Cookie('owner', 'core')]);

      // A different owner publishes its connection while the original core
      // still retains and must release the connection it acquired at startup.
      SingleInstanceCookieJar.instance = null;
      otherCookies = await SingleInstanceCookieJar.createInstance(
        directory: otherRoot.path,
      );
      expect(path.equals(ownedCookies.path, otherCookies.path), isFalse);
      otherCookies.saveFromResponse(uri, [Cookie('owner', 'other')]);
      await core.close();

      expect(() => ownedCookies.loadForRequest(uri), throwsStateError);
      expect(SingleInstanceCookieJar.instance, same(otherCookies));
      expect(otherCookies.loadForRequestCookieHeader(uri), 'owner=other');
      otherCookies.saveFromResponse(uri, [Cookie('owner', 'still-open')]);
      expect(otherCookies.loadForRequestCookieHeader(uri), 'owner=still-open');
      await root.delete(recursive: true);
      expect(await root.exists(), isFalse);
    },
    skip: !Platform.isWindows,
  );
}
