import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';

void main() {
  late Directory root;
  late AppdataImportCheckpoint before;
  late Map<String, dynamic> implicitBefore;

  setUp(() {
    root = Directory.systemTemp.createTempSync('appdata-admission-');
    App.dataPath = root.path;
    before = appdata.captureImportCheckpoint();
    implicitBefore =
        jsonDecode(jsonEncode(appdata.implicitData)) as Map<String, dynamic>;
    appdata.settings['disableSyncFields'] = '';
  });

  tearDown(() async {
    appdata.registerSyncDataRequestHandler(null);
    await appdata.restoreImportCheckpoint(before, persist: false);
    appdata.implicitData = implicitBefore;
    root.deleteSync(recursive: true);
  });

  Map<String, dynamic> read([String name = 'appdata.json']) =>
      jsonDecode(File(p.join(App.dataPath, name)).readAsStringSync())
          as Map<String, dynamic>;

  test('persistence intent runs at queue head before memory or disk', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final maintenance = appdata.runPersistenceMaintenance((path) async {
      expect(path, root.path);
      entered.complete();
      await release.future;
    });
    await entered.future;
    var recorded = false;
    final old = appdata.settings['cacheSize'];
    final editing = appdata.updateSettings(
      (draft) {
        draft['cacheSize'] = 852;
        draft['disableSyncFields'] = 'proxy';
      },
      sync: false,
      beforePersist: (contents) {
        recorded = true;
        expect(appdata.settings['cacheSize'], old);
        expect(File(p.join(root.path, 'appdata.json')).existsSync(), isFalse);
        expect(
          jsonDecode(contents['appdata.json']!)['settings']['cacheSize'],
          852,
        );
        expect(
          jsonDecode(
            contents['syncdata.json']!,
          )['settings'].containsKey('proxy'),
          isFalse,
        );
        expect(() => contents.clear(), throwsUnsupportedError);
        return null;
      },
    );
    await pumpEventQueue();
    expect(recorded, isFalse);
    release.complete();
    await Future.wait([maintenance, editing]);
    expect(recorded, isTrue);
    expect(read()['settings']['cacheSize'], 852);
  });

  test(
    'failed or async persistence intent does not publish the draft',
    () async {
      final old = appdata.settings['cacheSize'];
      final failure = StateError('journal unavailable');
      for (final asynchronous in [false, true]) {
        await expectLater(
          appdata.updateSettings(
            (draft) {
              draft['cacheSize'] = 853;
            },
            beforePersist: (_) {
              if (asynchronous) return Future<void>.value();
              throw failure;
            },
          ),
          asynchronous ? throwsArgumentError : throwsA(same(failure)),
        );
        expect(appdata.settings['cacheSize'], old);
        expect(File(p.join(root.path, 'appdata.json')).existsSync(), isFalse);
      }
    },
  );

  test(
    'exclusive startup can initialize ahead of a queued external caller',
    () async {
      final entered = Completer<void>();
      final proceed = Completer<void>();
      final replacing = AppDataOperations.instance.run(() async {
        entered.complete();
        await proceed.future;
        await appdata.init();
      });
      await entered.future;
      final external = appdata.init();
      proceed.complete();
      await Future.wait([
        replacing,
        external,
      ]).timeout(const Duration(seconds: 5));
      expect(read()['settings']['deviceId'], isNotEmpty);
    },
  );

  test(
    'queued edit waits before changing memory and uses replaced data and path',
    () async {
      appdata.settings['cacheSize'] = 100;
      final entered = Completer<void>();
      final proceed = Completer<void>();
      final replacementPath = p.join(root.path, 'replacement');
      final replacing = AppDataOperations.instance.run(() async {
        entered.complete();
        await proceed.future;
        App.dataPath = replacementPath;
        await appdata.syncData({
          'settings': {'cacheSize': 200},
          'searchHistory': ['imported'],
        });
      });
      await entered.future;
      final editing = appdata.updateSettings((settings) {
        settings['cacheSize'] = (settings['cacheSize'] as int) + 1;
      }, sync: false);
      await Future<void>.delayed(Duration.zero);
      expect(appdata.settings['cacheSize'], 100);
      expect(File(p.join(root.path, 'appdata.json')).existsSync(), isFalse);
      proceed.complete();
      await Future.wait([replacing, editing]);
      expect(read()['settings']['cacheSize'], 201);
      expect(appdata.searchHistory, ['imported']);
    },
  );

  test(
    'replacement waits for both real writes, including a late failed write',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final failure = StateError('filtered write failed');
      final hooks = _WriteHooks((path, _) async {
        if (p.basename(path) == 'syncdata.json.tmp') {
          entered.complete();
          await release.future;
          throw failure;
        }
      });
      var published = 0;
      var syncRequests = 0;
      void listener() => published++;
      appdata.settings.addListener(listener);
      addTearDown(() => appdata.settings.removeListener(listener));
      appdata.registerSyncDataRequestHandler(() => syncRequests++);
      final editing = IOOverrides.runWithIOOverrides(
        () => appdata.updateSettings((settings) {
          settings['cacheSize'] = 333;
          settings['disableSyncFields'] = 'proxy';
        }),
        hooks,
      );
      final checked = expectLater(editing, throwsA(same(failure)));
      await entered.future;
      var replaced = false;
      final replacement = AppDataOperations.instance.run(() => replaced = true);
      await Future<void>.delayed(Duration.zero);
      expect(replaced, isFalse);
      expect(published, 0);
      release.complete();
      await checked;
      await replacement;
      expect(read()['settings']['cacheSize'], 333);
      expect(appdata.settings['cacheSize'], 333);
      expect(published, 1);
      expect(syncRequests, 0);
      await appdata.saveData(false);
      expect(read('syncdata.json')['settings'].containsKey('proxy'), isFalse);
    },
  );

  test(
    'admitted persistence keeps its directory even if global path changes',
    () async {
      final originalPath = root.path;
      final entered = Completer<void>();
      final release = Completer<void>();
      final hooks = _WriteHooks((path, _) async {
        if (p.basename(path) == 'appdata.json.tmp') {
          entered.complete();
          await release.future;
        }
      });
      final first = IOOverrides.runWithIOOverrides(
        () => appdata.updateSettings((settings) {
          settings['cacheSize'] = 401;
        }, sync: false),
        hooks,
      );
      await entered.future;
      final second = appdata.updateImplicit(
        (data) => data['marker'] = 'old-directory',
      );
      App.dataPath = p.join(root.path, 'other');
      release.complete();
      await Future.wait([first, second]);
      expect(
        File(p.join(originalPath, 'implicitData.json')).existsSync(),
        isTrue,
      );
      expect(Directory(App.dataPath).existsSync(), isFalse);
    },
  );

  test('legacy flush captures contents after queued edits have run', () async {
    final editing = appdata.updateSettings(
      (settings) => settings['cacheSize'] = 987,
      sync: false,
    );
    final saving = appdata.saveData(false);
    final implicit = appdata.updateImplicit(
      (data) => data['new-key'] = ['value'],
    );
    final implicitSaving = appdata.writeImplicitData();
    await Future.wait([editing, saving, implicit, implicitSaving]);
    expect(read()['settings']['cacheSize'], 987);
    expect(read('implicitData.json')['new-key'], ['value']);
  });

  test(
    'unchanged repair skips writes but normal same-value save retries',
    () async {
      final value = appdata.settings['cacheSize'];
      final blocked = Directory(p.join(root.path, 'appdata.json.tmp'))
        ..createSync();
      await appdata.updateSettings(
        (draft) => draft['cacheSize'] = value,
        sync: false,
        persistIfUnchanged: false,
      );
      expect(File(p.join(root.path, 'appdata.json')).existsSync(), isFalse);
      await expectLater(
        appdata.updateSettings(
          (draft) => draft['cacheSize'] = value,
          sync: false,
        ),
        throwsA(isA<FileSystemException>()),
      );
      blocked.deleteSync();
      await appdata.updateSettings(
        (draft) => draft['cacheSize'] = value,
        sync: false,
      );
      expect(read()['settings']['cacheSize'], value);
    },
  );

  test(
    'field recovery captures input and preserves preceding queued edits',
    () async {
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      final edit = appdata.updateSettings((draft) {
        draft['quickFavorite'] = 'replaced';
        draft['cacheSize'] = 991;
      }, sync: false);
      final fields = <String, dynamic>{'quickFavorite': 'original'};
      final restoring = appdata.restoreSettingsFields(fields);
      fields['quickFavorite'] = 'mutated caller';
      release.complete();
      await Future.wait([exclusive, edit, restoring]);
      expect(read()['settings']['quickFavorite'], 'original');
      expect(read()['settings']['cacheSize'], 991);
    },
  );

  test(
    'throwing or unencodable edits leave memory and files untouched',
    () async {
      await appdata.saveData(false);
      final previous = File(
        p.join(root.path, 'appdata.json'),
      ).readAsStringSync();
      final size = appdata.settings['cacheSize'];
      var notifications = 0;
      void listener() => notifications++;
      appdata.settings.addListener(listener);
      addTearDown(() => appdata.settings.removeListener(listener));
      final failure = StateError('invalid edit');
      await expectLater(
        appdata.updateSettings<void>((settings) {
          settings['cacheSize'] = 999;
          (settings['blockedWords'] as List).add('draft only');
          throw failure;
        }),
        throwsA(same(failure)),
      );
      await expectLater(
        appdata.updateSettings<void>((settings) {
          settings['cacheSize'] = 999;
          settings['invalidJson'] = Object();
        }),
        throwsA(isA<JsonUnsupportedObjectError>()),
      );
      expect(appdata.settings['cacheSize'], size);
      expect(appdata.settings['blockedWords'], isNot(contains('draft only')));
      expect(appdata.settings['invalidJson'], isNull);
      expect(notifications, 0);
      expect(
        File(p.join(root.path, 'appdata.json')).readAsStringSync(),
        previous,
      );
      await appdata.updateSettings(
        (settings) => settings['cacheSize'] = 123,
        sync: false,
      );
      expect(read()['settings']['cacheSize'], 123);
    },
  );

  test(
    'retained drafts and nested values cannot mutate published data',
    () async {
      late Settings retained;
      late List words;
      await appdata.updateSettings((settings) {
        retained = settings;
        settings['blockedWords'] = ['saved'];
        words = settings['blockedWords'] as List;
      }, sync: false);
      retained['cacheSize'] = 777;
      words.add('late');
      late Map<String, dynamic> implicit;
      await appdata.updateImplicit((data) {
        implicit = data;
        data['nested'] = ['saved'];
      });
      (implicit['nested'] as List).add('late');
      expect(appdata.settings['cacheSize'], isNot(777));
      expect(appdata.settings['blockedWords'], ['saved']);
      expect(appdata.implicitData['nested'], ['saved']);
    },
  );

  test(
    'accidental async edit is rejected and its late draft stays detached',
    () async {
      final proceed = Completer<void>();
      final finished = Completer<void>();
      await expectLater(
        appdata.updateSettings((settings) async {
          settings['cacheSize'] = 778;
          await proceed.future;
          settings['cacheSize'] = 779;
          finished.complete();
        }),
        throwsArgumentError,
      );
      proceed.complete();
      await finished.future;
      expect(appdata.settings['cacheSize'], isNot(anyOf(778, 779)));
      expect(File(p.join(root.path, 'appdata.json')).existsSync(), isFalse);
    },
  );

  test(
    'search history edits serialize deduplication and trim to fifty',
    () async {
      appdata.searchHistory = List.generate(50, (index) => 'old-$index');
      await Future.wait([
        appdata.addSearchHistory('new'),
        appdata.addSearchHistory('old-10'),
        appdata.addSearchHistory('new'),
        appdata.removeSearchHistory('old-0'),
      ]);
      expect(appdata.searchHistory.take(2), ['new', 'old-10']);
      expect(
        appdata.searchHistory.where((item) => item == 'new'),
        hasLength(1),
      );
      expect(appdata.searchHistory, isNot(contains('old-0')));
      expect(appdata.searchHistory.length, 49);
      expect(read()['searchHistory'], appdata.searchHistory);
      await appdata.clearSearchHistory();
      expect(read()['searchHistory'], isEmpty);
    },
  );

  test('unrelated edits preserve legacy live collection references', () async {
    final words = appdata.settings['blockedWords'];
    final history = appdata.searchHistory;
    final implicit = appdata.implicitData;
    final nested = <String>['existing'];
    implicit['keep-reference'] = nested;
    await appdata.updateSettings(
      (settings) => settings['cacheSize'] = 713,
      sync: false,
    );
    await appdata.updateImplicit((data) => data['another-key'] = true);
    expect(identical(appdata.settings['blockedWords'], words), isTrue);
    expect(identical(appdata.searchHistory, history), isTrue);
    expect(identical(appdata.implicitData, implicit), isTrue);
    expect(identical(appdata.implicitData['keep-reference'], nested), isTrue);
  });

  test(
    'invalid sync filter is rejected before publication or either write',
    () async {
      var writes = 0;
      final hooks = _WriteHooks((_, _) async {
        writes++;
      });
      await expectLater(
        IOOverrides.runWithIOOverrides(
          () => appdata.updateSettings((settings) {
            settings['disableSyncFields'] = 123;
          }),
          hooks,
        ),
        throwsFormatException,
      );
      await Future<void>.delayed(Duration.zero);
      expect(writes, 0);
      expect(appdata.settings['disableSyncFields'], '');
      expect(File(p.join(root.path, 'appdata.json')).existsSync(), isFalse);
    },
  );

  test(
    'unrelated edits preserve a malformed legacy sync filter on disk',
    () async {
      appdata.settings['disableSyncFields'] = 123;
      await appdata.updateSettings(
        (settings) => settings['cacheSize'] = 901,
        sync: false,
      );
      expect(appdata.settings['disableSyncFields'], 123);
      expect(read()['settings']['disableSyncFields'], 123);
      expect(read()['settings']['cacheSize'], 901);
      expect(File(p.join(root.path, 'syncdata.json')).existsSync(), isFalse);
    },
  );

  test(
    'idle queue does not schedule later writes through a retired caller zone',
    () async {
      var retired = false;
      var staleSchedules = 0;
      final first = runZoned(
        () => appdata.updateSettings((settings) {
          settings['cacheSize'] = 810;
        }, sync: false),
        zoneSpecification: ZoneSpecification(
          scheduleMicrotask: (self, parent, zone, callback) {
            if (retired) staleSchedules++;
            parent.scheduleMicrotask(zone, callback);
          },
        ),
      );
      await first;
      retired = true;
      await appdata.updateSettings(
        (settings) => settings['cacheSize'] = 811,
        sync: false,
      );
      expect(staleSchedules, 0);
      expect(read()['settings']['cacheSize'], 811);
    },
  );

  test(
    'nested save queues behind the draft and publishes nested changes once',
    () async {
      var notifications = 0;
      void listener() => notifications++;
      appdata.settings.addListener(listener);
      addTearDown(() => appdata.settings.removeListener(listener));
      Future<void>? nested;
      await appdata
          .updateSettings((settings) {
            (settings['blockedWords'] as List).add('nested');
            nested = appdata.saveData(false);
          }, sync: false)
          .timeout(const Duration(seconds: 5));
      await nested;
      expect(notifications, 1);
      expect(read()['settings']['blockedWords'], contains('nested'));
    },
  );

  test('import captures input and filters against admitted settings', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final replacing = AppDataOperations.instance.run(() async {
      entered.complete();
      await release.future;
      await appdata.updateSettings((settings) {
        settings['disableSyncFields'] = 'cacheSize';
        settings['cacheSize'] = 500;
      }, sync: false);
    });
    await entered.future;
    final input = <String, dynamic>{
      'settings': {'cacheSize': 600, 'language': 'en-US'},
      'searchHistory': ['captured'],
    };
    final importing = appdata.syncData(input);
    (input['settings'] as Map)['language'] = 'zh-CN';
    (input['searchHistory'] as List).clear();
    release.complete();
    await Future.wait([replacing, importing]);
    expect(appdata.settings['cacheSize'], 500);
    expect(appdata.settings['language'], 'en-US');
    expect(appdata.searchHistory, ['captured']);
  });

  test(
    'listeners cannot borrow edit access to bypass waiting replacement',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final events = <String>[];
      final hooks = _WriteHooks((_, _) async {
        if (entered.isCompleted) return;
        entered.complete();
        await release.future;
      });
      Future<void>? next;
      void listener() {
        if (next != null) return;
        next = appdata.updateSettings((settings) {
          events.add('listener edit');
          settings['cacheSize'] = 702;
        }, sync: false);
      }

      appdata.settings.addListener(listener);
      addTearDown(() => appdata.settings.removeListener(listener));
      final editing = IOOverrides.runWithIOOverrides(
        () => appdata.updateSettings((settings) {
          settings['cacheSize'] = 701;
        }, sync: false),
        hooks,
      );
      await entered.future;
      final replacing = AppDataOperations.instance.run(
        () => events.add('replacement'),
      );
      release.complete();
      await Future.wait([editing, replacing]);
      await next;
      expect(events, ['replacement', 'listener edit']);
      expect(read()['settings']['cacheSize'], 702);
    },
  );
}

final class _WriteHooks extends IOOverrides {
  _WriteHooks(this.beforeWrite);
  final Future<void> Function(String, String) beforeWrite;

  @override
  File createFile(String path) =>
      _HookedFile(super.createFile(path), beforeWrite);
}

class _HookedFile implements File {
  _HookedFile(this.raw, this.beforeWrite);
  final File raw;
  final Future<void> Function(String, String) beforeWrite;
  @override
  String get path => raw.path;
  @override
  Directory get parent => raw.parent;
  @override
  Future<bool> exists() => raw.exists();
  @override
  Future<File> copy(String newPath) => raw.copy(newPath);
  @override
  Future<File> rename(String newPath) => raw.rename(newPath);
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      raw.delete(recursive: recursive);
  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    await beforeWrite(path, contents);
    return raw.writeAsString(
      contents,
      mode: mode,
      encoding: encoding,
      flush: flush,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
