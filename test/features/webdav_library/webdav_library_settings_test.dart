import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/webdav_library/webdav_library.dart';

void main() {
  WebDavLibrarySettings read(Map<String, Object?> values) =>
      WebDavLibrarySettings.read((key) => values[key]);

  Map<String, Object?> legacy() => {
    'webdavComicLibrary': [' https://example.com/dav ', ' user ', ' pass '],
    'webdavComicLibraryPath': '/manga',
    'webdavComicLibraryAutoSync': true,
    'webdavComicLibrarySyncIntervalMinutes': 60,
    'futureSetting': 'preserved',
  };

  test('legacy settings round-trip without rewriting unrelated keys', () async {
    final values = legacy();
    final store = WebDavLibrarySettingsStore(
      readValue: (key) => values[key],
      persist: (patch) async => values.addAll(patch.toSettings()),
    );
    final settings = store.read();
    expect(settings.connection.url, 'https://example.com/dav');
    expect(settings.connection.user, 'user');
    expect(settings.connection.pass, 'pass');
    expect(settings.connection.remotePath, '/manga/');
    expect(settings.autoSync, isTrue);
    expect(settings.intervalMinutes, 60);
    // Merely reading does not normalize the backing map.
    expect(values['webdavComicLibraryPath'], '/manga');
    await store.save(settings);
    expect(values['futureSetting'], 'preserved');
    expect(values['webdavComicLibrary'], [
      'https://example.com/dav',
      'user',
      'pass',
    ]);
    expect(
      store.read().connection.connectionKey,
      settings.connection.connectionKey,
    );
  });

  test('malformed credentials are disabled without dropping path', () {
    for (final credentials in [
      null,
      'url',
      [],
      ['url', 'user'],
      ['url', 7, 'pass'],
      ['url', 'user', 'pass', 7],
    ]) {
      final values = legacy()..['webdavComicLibrary'] = credentials;
      final settings = read(values);
      expect(settings.connection.isValid, isFalse);
      expect(settings.connection.remotePath, '/manga/');
      expect(settings.toSettings()['webdavComicLibrary'], isEmpty);
      expect(values['webdavComicLibrary'], credentials);
    }
  });

  test('invalid scheduling values have safe read-only defaults', () {
    for (final interval in [null, '60', -1, 0, double.nan, double.infinity]) {
      final values = legacy()
        ..['webdavComicLibraryAutoSync'] = 'true'
        ..['webdavComicLibrarySyncIntervalMinutes'] = interval
        ..['webdavComicLibraryPath'] = 7;
      final settings = read(values);
      expect(settings.autoSync, isFalse);
      expect(settings.intervalMinutes, 360);
      expect(settings.connection.remotePath, '/venera_comics/');
    }
    expect(read({}).autoSync, isFalse);
    expect(
      read(
        legacy()..['webdavComicLibrarySyncIntervalMinutes'] = 42.6,
      ).intervalMinutes,
      43,
    );
  });

  test('schedule-only save does not invalidate remote content', () async {
    final values = legacy();
    final store = WebDavLibrarySettingsStore(
      readValue: (key) => values[key],
      persist: (patch) async => values.addAll(patch.toSettings()),
    );
    await store.save(
      WebDavLibrarySettings(
        connection: store.read().connection,
        autoSync: false,
        intervalMinutes: 1440,
      ),
    );
    expect(store.read().autoSync, isFalse);
    expect(store.read().intervalMinutes, 1440);
  });

  test(
    'password change waits for the composition persistence callback',
    () async {
      final values = legacy();
      final persisted = Completer<void>();
      final store = WebDavLibrarySettingsStore(
        readValue: (key) => values[key],
        persist: (patch) async {
          await persisted.future;
          values.addAll(patch.toSettings());
        },
      );
      final previous = store.read().connection;
      final updated = read(
        legacy()
          ..['webdavComicLibrary'] = ['https://example.com/dav', 'user', 'new'],
      );
      expect(updated.connection.cacheKey, previous.cacheKey);
      expect(updated.connection.connectionKey, isNot(previous.connectionKey));
      final saving = store.save(updated);
      expect(store.read().connection.connectionKey, previous.connectionKey);
      persisted.complete();
      await saving;
      expect(
        store.read().connection.connectionKey,
        updated.connection.connectionKey,
      );
    },
  );

  test('persistence failure propagates without success notification', () async {
    final values = legacy();
    final store = WebDavLibrarySettingsStore(
      readValue: (key) => values[key],
      persist: (_) async => throw StateError('write failed'),
    );
    await expectLater(store.save(read({})), throwsStateError);
    expect(store.read().connection.isValid, isTrue);
  });

  test(
    'independent stores do not share configuration or notifications',
    () async {
      final first = legacy();
      final second = legacy();
      var changed = 0;
      final firstStore = WebDavLibrarySettingsStore(
        readValue: (key) => first[key],
        persist: (patch) async {
          first.addAll(patch.toSettings());
          changed++;
        },
      );
      final secondStore = WebDavLibrarySettingsStore(
        readValue: (key) => second[key],
        persist: (patch) async => second.addAll(patch.toSettings()),
      );
      await firstStore.save(read({}));
      expect(firstStore.read().connection.isValid, isFalse);
      expect(secondStore.read().connection.isValid, isTrue);
      expect(changed, 1);
    },
  );
}
