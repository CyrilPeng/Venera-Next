import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/cache_settings.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/cache_scan.dart';

void main() {
  test('cache preference normalizes legacy values within safe byte bounds', () {
    final preference = AppPreferences.cacheSize;
    expect(preference.normalize(null), 2048);
    expect(preference.normalize('1024'), 2048);
    expect(preference.normalize(double.nan), 2048);
    expect(preference.normalize(-1), 0);
    expect(preference.normalize(1.9), 1);
    final maximum = preference.normalize(1e30).toInt();
    expect(maximum, AppPreferences.maxCacheSizeMb);
    expect(maximum * 1024 * 1024, greaterThan(0));
    expect(AppPreferences.authorizationRequired.normalize(null), isFalse);
  });

  test(
    'binding applies settings changes and detaches from its cache',
    () async {
      final root = Directory.systemTemp.createTempSync('cache-settings-');
      final cache = CacheManager.open(
        dataPath: root.path,
        cacheRoot: root.path,
      );
      final settings = appdata.settings;
      final previous = settings['cacheSize'];
      addTearDown(() => settings['cacheSize'] = previous);
      settings['cacheSize'] = 1;
      final binding = CacheSettingsBinding(settings, cache);
      addTearDown(() async {
        binding.dispose();
        await cache.dispose();
        root.deleteSync(recursive: true);
      });
      await cache.writeCache('kept', [1]);
      expect(await cache.findCache('kept'), isNotNull);
      settings['cacheSize'] = 0;
      await cache.writeCache('evicted', [2]);
      expect(await cache.findCache('evicted'), isNull);
      settings['cacheSize'] = 1;
      binding.dispose();
      binding.dispose();
      settings['cacheSize'] = 0;
      await cache.writeCache('detached', [3]);
      expect(await cache.findCache('detached'), isNotNull);
      expect(CacheManager.instance, isNull);
    },
  );

  test(
    'closing cache ignores late settings without touching replacement',
    () async {
      final root = Directory.systemTemp.createTempSync('cache-settings-close-');
      final nextRoot = Directory('${root.path}/replacement')..createSync();
      final gate = Completer<CacheScanResult>();
      final cache = CacheManager.open(
        dataPath: root.path,
        cacheRoot: root.path,
        scanner: (_, _) => gate.future,
      );
      final settings = appdata.settings;
      final previous = settings['cacheSize'];
      addTearDown(() => settings['cacheSize'] = previous);
      settings['cacheSize'] = 1;
      final binding = CacheSettingsBinding(settings, cache);
      final scanning = cache.start();
      final closing = cache.dispose();
      final replacement = CacheManager.open(
        dataPath: nextRoot.path,
        cacheRoot: nextRoot.path,
      );
      CacheManager.instance = replacement;
      addTearDown(() async {
        binding.dispose();
        if (!gate.isCompleted) gate.complete(const CacheScanResult(0, []));
        await closing;
        await replacement.dispose();
        root.deleteSync(recursive: true);
      });
      settings['cacheSize'] = 0;
      gate.complete(const CacheScanResult(0, []));
      await Future.wait([scanning, closing]);
      expect(CacheManager.instance, same(replacement));
      settings['cacheSize'] = 0;
      await replacement.writeCache('untouched', [1]);
      expect(await replacement.findCache('untouched'), isNotNull);
    },
  );
}
