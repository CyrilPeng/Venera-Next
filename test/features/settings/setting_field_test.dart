import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/settings/setting_field.dart';
import 'package:venera_next/foundation/preferences.dart';
import 'package:venera_next/foundation/reader_preference_settings.dart';
import 'package:venera_next/foundation/reader_preference_store.dart';
import 'package:venera_next/foundation/reader_preferences.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'package:venera_next/foundation/global_preference_store.dart';

// A recording port, not an Appdata replacement: production inheritance and
// persistence are exercised by reader_preference_store/setting_persistence.
class _Settings implements ReaderPreferenceSettings {
  final values = <(String, String?, String?, String), Object?>{};
  final reads = <(String, String?, String?, String)>[];
  String activeScope = 'global';

  Object? _read(String scope, String? comic, String? source, String key) {
    final target = (scope, comic, source, key);
    reads.add(target);
    return values[target];
  }

  @override
  Object? operator [](String key) => _read('global', null, null, key);
  @override
  void operator []=(String key, Object? value) =>
      values[('global', null, null, key)] = value;
  @override
  Object? getDeviceReaderSetting(String key) =>
      _read('device', null, null, key);
  @override
  Object? getReaderSetting(String comicId, String sourceKey, String key) =>
      _read('comic', comicId, sourceKey, key);
  @override
  void setDeviceReaderSetting(String key, Object? value) =>
      values[('device', null, null, key)] = value;
  @override
  void setReaderSetting(
    String comicId,
    String sourceKey,
    String key,
    Object? value,
  ) => values[('comic', comicId, sourceKey, key)] = value;
  @override
  void setActiveReaderSetting(
    String? comicId,
    String? sourceKey,
    String key,
    Object? value,
  ) =>
      values[(
            activeScope,
            activeScope == 'comic' ? comicId : null,
            activeScope == 'comic' ? sourceKey : null,
            key,
          )] =
          value;
}

void main() {
  test('nullable normalization never falls back to an invalid raw value', () {
    final settings = _Settings()..['defaultSearchTarget'] = 42;
    final store = SettingFieldStore(
      readSettings: () => settings,
      updateSettings: (_) => throw StateError('read only'),
    );
    const field = SettingField<String?>(
      key: 'defaultSearchTarget',
      preference: DiscoveryPreferences.defaultSearchTarget,
    );
    expect(store.read(field), isNull);
    expect(settings['defaultSearchTarget'], 42);
    settings['defaultSearchTarget'] = 'retired';
    expect(store.read(field), 'retired');
  });

  test(
    'nullable edits await admission and persist clear separately from empty',
    () async {
      final current = _Settings()..['searchSources'] = ['current'];
      final draft = _Settings()..['searchSources'] = ['old'];
      final admission = Completer<void>();
      final store = SettingFieldStore(
        readSettings: () => current,
        updateSettings: (change) async {
          await admission.future;
          change(draft);
        },
      );
      const field = SettingField<List<String>?>(
        key: 'searchSources',
        preference: DiscoveryPreferences.searchSources,
      );
      final save = store.save(field, null);
      expect(draft['searchSources'], ['old']);
      admission.complete();
      await save;
      expect(draft['searchSources'], isNull);
      expect(current['searchSources'], ['current']);
      await store.save(field, <String>[]);
      expect(draft['searchSources'], isEmpty);
      final sources = ['missing', 'known', 'missing'];
      final next = store.save(field, sources);
      sources.clear();
      await next;
      expect(draft['searchSources'], ['missing', 'known', 'missing']);
    },
  );

  test('global typed reads leave recovery bytes and unrelated keys intact', () {
    final settings = _Settings();
    final raw = jsonDecode('["unknown",5,null,"known",""]') as List;
    settings['searchSources'] = raw;
    settings['future-key'] = {'enabled': true};
    final before = jsonEncode(raw);
    final store = GlobalPreferenceStore(settings);
    expect(store.read(DiscoveryPreferences.searchSources), [
      'unknown',
      'known',
      '',
    ]);
    expect(jsonEncode(settings['searchSources']), before);
    store.write(DiscoveryPreferences.defaultSearchTarget, null);
    expect(settings['defaultSearchTarget'], isNull);
    store.write(DiscoveryPreferences.searchSources, <String>[]);
    expect(settings['searchSources'], isEmpty);
    expect(settings['future-key'], {'enabled': true});
  });

  test('reads current owner and normalizes without changing stored values', () {
    var settings = _Settings()..['readerBrightness'] = 'invalid';
    final store = SettingFieldStore(
      readSettings: () => settings,
      updateSettings: (_) => throw StateError('read only'),
    );
    const field = SettingField<num>(
      key: 'readerBrightness',
      preference: ReaderPreferences.readerBrightness,
    );
    expect(store.read(field), 50);
    expect(settings['readerBrightness'], 'invalid');
    settings = _Settings()..['readerBrightness'] = 42.6;
    expect(store.read(field), 42.6);
    settings['readerBrightness'] = double.nan;
    expect(store.read(field), 50);
    expect((settings['readerBrightness'] as double).isNaN, isTrue);
  });

  test(
    'explicit targets keep comic, source and device reads distinct',
    () async {
      final settings = _Settings();
      final store = SettingFieldStore(
        readSettings: () => settings,
        updateSettings: (change) async => change(settings),
      );
      final fields = [
        const SettingField<String>(key: 'option'),
        const SettingField<String>.reader(
          key: 'option',
          useDeviceSettings: true,
        ),
        const SettingField<String>.reader(
          key: 'option',
          comicId: 'comic',
          sourceKey: 'source',
          useDeviceSettings: true,
        ),
        const SettingField<String>.reader(
          key: 'option',
          comicId: 'comic',
          sourceKey: 'another-source',
        ),
      ];
      for (var i = 0; i < fields.length; i++) {
        await store.save(fields[i], 'value-$i');
      }
      expect(fields.map(store.read), [
        'value-0',
        'value-1',
        'value-2',
        'value-3',
      ]);
      expect(settings.reads, [
        ('global', null, null, 'option'),
        ('device', null, null, 'option'),
        ('comic', 'comic', 'source', 'option'),
        ('comic', 'comic', 'another-source', 'option'),
      ]);
    },
  );

  test(
    'legacy lists are captured before admission and nullable fields survive',
    () async {
      final current = _Settings()..['target'] = null;
      final draft = _Settings()..['unknown'] = {'keep': true};
      final admission = Completer<void>();
      final persisted = Completer<void>();
      final store = SettingFieldStore(
        readSettings: () => current,
        updateSettings: (change) async {
          await admission.future;
          change(draft);
          await persisted.future;
        },
      );
      expect(store.read(const SettingField<String>(key: 'target')), isNull);
      final input = <String>['old-source', 'new-source'];
      var finished = false;
      final save = store
          .save(const SettingField<List<Object?>>(key: 'pages'), input)
          .then((_) => finished = true);
      input
        ..clear()
        ..add('changed-after-save');
      expect(draft['pages'], isNull);
      admission.complete();
      await Future<void>.delayed(Duration.zero);
      expect(draft['pages'], ['old-source', 'new-source']);
      expect(current['pages'], isNull);
      expect(finished, isFalse);
      persisted.complete();
      await save;
      expect(draft['unknown'], {'keep': true});
      current['pages'] = jsonDecode('["","missing-source","kept"]');
      expect(store.read(const SettingField<List<Object?>>(key: 'pages')), [
        '',
        'missing-source',
        'kept',
      ]);
    },
  );

  test(
    'typed mutable values are frozen and whole numbers keep integer JSON',
    () async {
      final settings = _Settings();
      final admission = Completer<void>();
      final store = SettingFieldStore(
        readSettings: () => settings,
        updateSettings: (change) async {
          await admission.future;
          change(settings);
        },
      );
      final input = {'source': 'original'};
      final saves = [
        store.save(
          const SettingField<Map<String, String>>(
            key: 'mapping',
            preference: StringMapPreference('mapping'),
          ),
          input,
        ),
        store.save(const SettingField<num>(key: 'legacyWhole'), 20.0),
        store.save(const SettingField<num>(key: 'legacyFraction'), 20.5),
        store.save(
          const SettingField<num>(
            key: 'readerBrightness',
            preference: ReaderPreferences.readerBrightness,
          ),
          double.infinity,
        ),
      ];
      input['source'] = 'changed';
      admission.complete();
      await Future.wait(saves);
      expect(settings['mapping'], {'source': 'original'});
      expect(settings['legacyWhole'], isA<int>());
      expect(settings['legacyFraction'], 20.5);
      expect(settings['readerBrightness'], 50);
      expect(settings['readerBrightness'], isA<int>());
    },
  );

  test(
    'active scope and linked comments resolve against the admitted draft',
    () async {
      final current = _Settings();
      final draft = _Settings();
      final admission = Completer<void>();
      final store = SettingFieldStore(
        readSettings: () => current,
        updateSettings: (change) async {
          await admission.future;
          change(draft);
        },
      );
      const field = SettingField<bool>(
        key: 'showChapterComments',
        preference: ReaderPreferences.showChapterComments,
        comicId: 'original-comic',
        sourceKey: 'original-source',
        scope: ReaderPreferenceScope.active,
      );
      final save = store.save(field, false);
      draft.activeScope = 'comic';
      admission.complete();
      await save;
      expect(current.values, isEmpty);
      expect(draft.values, {
        ('comic', 'original-comic', 'original-source', 'showChapterComments'):
            false,
        (
          'comic',
          'original-comic',
          'original-source',
          'showChapterCommentsAtEnd',
        ): false,
      });
      draft.activeScope = 'device';
      await store.save(field, true);
      expect(
        draft.values[('device', null, null, 'showChapterComments')],
        isTrue,
      );
      expect(
        draft.values.containsKey((
          'device',
          null,
          null,
          'showChapterCommentsAtEnd',
        )),
        isFalse,
      );
    },
  );

  test(
    'save exposes original persistence failure and a later save can retry',
    () async {
      final first = _Settings(), second = _Settings();
      final failure = StateError('disk unavailable');
      final stack = StackTrace.current;
      var failWrites = true;
      final store = SettingFieldStore(
        readSettings: () => first,
        updateSettings: (change) async {
          change(first);
          if (failWrites) Error.throwWithStackTrace(failure, stack);
        },
      );
      final independent = SettingFieldStore(
        readSettings: () => second,
        updateSettings: (change) async => change(second),
      );
      const field = SettingField<String>(key: 'value');
      Object? observed;
      StackTrace? observedStack;
      await store
          .save(field, 'first')
          .then<void>(
            (_) => fail('Expected failure'),
            onError: (Object error, StackTrace trace) {
              observed = error;
              observedStack = trace;
            },
          );
      expect(observed, same(failure));
      expect(observedStack.toString(), stack.toString());
      await independent.save(field, 'independent');
      failWrites = false;
      await store.save(field, 'retry');
      expect(store.read(field), 'retry');
      expect(independent.read(field), 'independent');
    },
  );

  test(
    'invalid legacy JSON never enters persistence; typed choices normalize',
    () async {
      final settings = _Settings();
      var submissions = 0;
      final store = SettingFieldStore(
        readSettings: () => settings,
        updateSettings: (change) async {
          submissions++;
          change(settings);
        },
      );
      expect(
        () => store.save(const SettingField<num>(key: 'legacy'), double.nan),
        throwsA(isA<JsonUnsupportedObjectError>()),
      );
      expect(submissions, 0);
      await store.save(
        const SettingField<String>(
          key: 'autoScrollStyle',
          preference: ReaderPreferences.autoScrollStyle,
        ),
        'invalid',
      );
      expect(settings['autoScrollStyle'], 'smooth');
    },
  );
}
