import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/source_failure.dart';
import 'package:venera_next/features/comic_source/source_repositories.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';

void main() {
  late Directory root;
  late AppdataImportCheckpoint before;
  late SourceRepositories store;
  late Dio client;
  late _Catalog adapter;
  setUp(() async {
    before = appdata.captureImportCheckpoint();
    root = Directory.systemTemp.createTempSync('source-preferences-');
    App.dataPath = root.path;
    await appdata.init();
    appdata.settings['disableSyncFields'] = '';
    appdata.settings['comicSourceRepositories'] = [];
    appdata.settings['comicSourceOrigins'] = <String, dynamic>{};
    appdata.settings['comicSourceRepositoriesMigrated'] = false;
    appdata.settings['comicSourceListUrl'] = '';
    adapter = _Catalog();
    client = Dio()..httpClientAdapter = adapter;
    store = SourceRepositories.forTesting(client);
  });
  tearDown(() async {
    appdata.registerSyncDataRequestHandler(null);
    client.close(force: true);
    store.dispose();
    await appdata.restoreImportCheckpoint(before, persist: false);
    root.deleteSync(recursive: true);
  });
  Map saved([String name = 'appdata.json']) =>
      (jsonDecode(File('${root.path}/$name').readAsStringSync())
              as Map)['settings']
          as Map;
  SourceRepositorySave draft(String name, {String? id, String? url}) =>
      store.prepareSave(
        id: id,
        name: name,
        url: url ?? 'https://$name.example/catalog.json',
        catalogContents: '[]',
      );
  Matcher failure(SourceFailureCode code) =>
      isA<SourceFailure>().having((e) => e.code, 'code', code);

  test('queued repository and origin edits merge at admission', () async {
    final release = Completer<void>();
    final replacement = AppDataOperations.instance.run(() => release.future);
    final first = draft('first').save();
    final second = draft('second').save();
    final origin = store.setOrigin('first', const SourceOrigin(kind: 'file'));
    expect(store.all, isEmpty);
    expect(store.originFor('first'), isNull);
    release.complete();
    await Future.wait([replacement, first, second, origin]);
    expect(store.all.map((e) => e.name), ['first', 'second']);
    expect(saved()['comicSourceRepositories'], hasLength(2));
    expect(saved()['comicSourceOrigins']['first']['kind'], 'file');
  });

  test(
    'two validated additions still reject duplicates at the draft queue head',
    () async {
      final release = Completer<void>();
      final replacement = AppDataOperations.instance.run(() => release.future);
      final first = draft(
        'one',
        url: 'https://same.example/catalog.json',
      ).save();
      final second = draft(
        'two',
        url: 'https://same.example/catalog.json',
      ).save();
      final rejected = expectLater(
        second,
        throwsA(failure(SourceFailureCode.duplicateRepository)),
      );
      release.complete();
      await Future.wait([replacement, first, rejected]);
      expect(store.all.single.name, 'one');
    },
  );

  test(
    'partial save invalidates consumers and retry reuses ID and validation',
    () async {
      appdata.settings['disableSyncFields'] = 'proxy';
      final blocked = Directory('${root.path}/syncdata.json.tmp')..createSync();
      final request = store.prepareSave(
        name: 'one',
        url: 'https://one.example/catalog.json',
      );
      var notified = 0;
      store.addListener(() => notified++);
      try {
        await expectLater(request.save(), throwsA(isA<FileSystemException>()));
        expect(store.all.single.id, request.repository.id);
        expect(
          saved()['comicSourceRepositories'].single['id'],
          request.repository.id,
        );
        expect(notified, 1);
      } finally {
        blocked.deleteSync();
      }
      await store.setOrigin(
        'other',
        const SourceOrigin(kind: 'url', url: 'https://other.example/s.js'),
      );
      await request.save();
      expect(adapter.requests, 1);
      expect(store.all, hasLength(1));
      expect(
        saved('syncdata.json')['comicSourceOrigins']['other']['kind'],
        'url',
      );
    },
  );

  test(
    'failed request cannot overwrite a later edit or recreate a removed repository',
    () async {
      final request = draft('one');
      final blocked = Directory('${root.path}/appdata.json.tmp')..createSync();
      await expectLater(request.save(), throwsA(isA<FileSystemException>()));
      blocked.deleteSync();
      final updated = await draft('updated', id: request.repository.id).save();
      await expectLater(
        request.save(),
        throwsA(failure(SourceFailureCode.repositoryChanged)),
      );
      expect(store.all.single.name, 'updated');
      await store.remove(updated);
      await expectLater(
        request.save(),
        throwsA(failure(SourceFailureCode.missingRepository)),
      );
      expect(store.all, isEmpty);
    },
  );

  test(
    'network validation does not hold admission and late results recheck the target',
    () async {
      final original = await draft('one').save();
      adapter.release = Completer<void>();
      final editing = store.save(
        id: original.id,
        name: 'network',
        url: 'https://network.example/catalog.json',
      );
      final rejected = expectLater(
        editing,
        throwsA(failure(SourceFailureCode.repositoryChanged)),
      );
      await adapter.entered.future;
      await AppDataOperations.instance.run(
        () => draft('replacement', id: original.id).save(),
      );
      adapter.release!.complete();
      await rejected;
      expect(store.all.single.name, 'replacement');
    },
  );

  test(
    'link validation and remove metadata use latest queued settings',
    () async {
      final repository = await draft('one').save();
      const entry = SourceCatalogEntry(
        key: 'source',
        name: 'Source',
        version: '1.0.0',
        url: 'https://one.example/s.js',
      );
      final release = Completer<void>();
      final replacement = AppDataOperations.instance.run(() => release.future);
      final edit = appdata.updateSettings((settings) {
        settings['comicSourceRepositories'] = [
          SourceRepository(
            id: repository.id,
            name: 'Changed',
            url: 'https://changed.example',
          ).toJson(),
        ];
      }, sync: false);
      final linking = expectLater(
        store.link('source', repository, entry),
        throwsA(failure(SourceFailureCode.repositoryChanged)),
      );
      final removing = expectLater(
        store.remove(repository),
        throwsA(failure(SourceFailureCode.repositoryChanged)),
      );
      release.complete();
      await Future.wait([replacement, edit, linking, removing]);
      expect(store.originFor('source'), isNull);
      expect(store.all.single.name, 'Changed');
    },
  );

  test(
    'unlink retries persistence but cannot remove a replacement link',
    () async {
      const original = SourceOrigin(kind: 'repository', repositoryId: 'one');
      await store.setOrigin('key', original);
      final blocked = Directory('${root.path}/appdata.json.tmp')..createSync();
      await expectLater(
        store.unlink('key', original),
        throwsA(isA<FileSystemException>()),
      );
      blocked.deleteSync();
      await store.unlink('key', original);
      expect(
        (saved()['comicSourceOrigins'] as Map).containsKey('key'),
        isFalse,
      );
      await store.setOrigin(
        'key',
        const SourceOrigin(kind: 'repository', repositoryId: 'two'),
      );
      await expectLater(
        store.unlink('key', original),
        throwsA(failure(SourceFailureCode.repositoryChanged)),
      );
      expect(store.originFor('key')!.repositoryId, 'two');
    },
  );

  test(
    'exclusive migration does not wait on a caller queued behind itself',
    () async {
      appdata.settings['comicSourceListUrl'] =
          'https://legacy.example/catalog.json';
      final entered = Completer<void>();
      final release = Completer<void>();
      final replacing = AppDataOperations.instance.run(() async {
        entered.complete();
        await release.future;
        await store.migrate();
      });
      await entered.future;
      final external = store.migrate();
      release.complete();
      await Future.wait([
        replacing,
        external,
      ]).timeout(const Duration(seconds: 5));
      expect(store.all.single.url, 'https://legacy.example/catalog.json');
    },
  );

  test(
    'migration retries unchanged published state without allocating another ID',
    () async {
      appdata.settings['comicSourceListUrl'] =
          'https://legacy.example/catalog.json';
      final blocked = Directory('${root.path}/appdata.json.tmp')..createSync();
      await expectLater(store.migrate(), throwsA(isA<FileSystemException>()));
      final id = store.all.single.id;
      await expectLater(store.migrate(), throwsA(isA<FileSystemException>()));
      expect(store.all.single.id, id);
      blocked.deleteSync();
      await store.migrate();
      expect(saved()['comicSourceRepositories'].single['id'], id);
      expect(saved()['comicSourceRepositoriesMigrated'], isTrue);
    },
  );

  test(
    'repository notifications cannot lend access to a replacement',
    () async {
      final release = Completer<void>();
      var replaced = false;
      Future<void>? replacement;
      store.addListener(() {
        replacement = AppDataOperations.instance.run<void>(() {
          replaced = true;
        });
      });
      final outer = AppDataOperations.instance.access(() async {
        await store.setOrigin('key', const SourceOrigin(kind: 'file'));
        expect(replaced, isFalse);
        await release.future;
      });
      await Future<void>.delayed(Duration.zero);
      release.complete();
      await outer;
      await replacement;
      expect(replaced, isTrue);
    },
  );
}

class _Catalog implements HttpClientAdapter {
  var requests = 0;
  final entered = Completer<void>();
  Completer<void>? release;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    if (!entered.isCompleted) entered.complete();
    await release?.future;
    return ResponseBody.fromString(
      '[]',
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
