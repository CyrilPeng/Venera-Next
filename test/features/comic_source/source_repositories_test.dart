import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/comic_source/source_repositories.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dataDir;
  late dynamic originalListUrl;
  late dynamic originalRepositories;
  late dynamic originalOrigins;
  late dynamic originalMigrated;

  setUp(() async {
    dataDir = Directory.systemTemp.createTempSync(
      'venera-source-repositories-',
    );
    App.dataPath = dataDir.path;
    originalListUrl = appdata.settings['comicSourceListUrl'];
    originalRepositories = appdata.settings['comicSourceRepositories'];
    originalOrigins = appdata.settings['comicSourceOrigins'];
    originalMigrated = appdata.settings['comicSourceRepositoriesMigrated'];
    appdata.settings['comicSourceListUrl'] = '';
    appdata.settings['comicSourceRepositories'] = <Map<String, dynamic>>[];
    appdata.settings['comicSourceOrigins'] = <String, dynamic>{};
    appdata.settings['comicSourceRepositoriesMigrated'] = false;
    // Initialize the singleton against the temporary directory so that no test
    // touches the real application data.
    await appdata.init();
  });

  tearDown(() {
    appdata.settings['comicSourceListUrl'] = originalListUrl;
    appdata.settings['comicSourceRepositories'] = originalRepositories;
    appdata.settings['comicSourceOrigins'] = originalOrigins;
    appdata.settings['comicSourceRepositoriesMigrated'] = originalMigrated;
    if (dataDir.existsSync()) {
      dataDir.deleteSync(recursive: true);
    }
  });

  group('normalizeUrl', () {
    const invalidUrl = 'Enter a complete HTTP or HTTPS URL.';

    test('rejects unsupported schemes, relative addresses and empty hosts', () {
      for (final value in [
        '',
        '   ',
        'example.com/index.json',
        'not a url',
        'ftp://example.com/index.json',
        'file:///tmp/index.json',
        'javascript:alert(1)',
        'http://',
        'https://',
      ]) {
        expect(
          () => SourceRepositories.normalizeUrl(value),
          throwsA(invalidUrl.tl),
          reason: 'expected [$value] to be rejected',
        );
      }
    });

    test('trims input, drops fragments and preserves path and query', () {
      expect(
        SourceRepositories.normalizeUrl(
          '  https://example.com/index.json#section  ',
        ),
        'https://example.com/index.json',
      );
      expect(
        SourceRepositories.normalizeUrl('https://example.com/a/b?x=1#y'),
        'https://example.com/a/b?x=1',
      );
      expect(
        SourceRepositories.normalizeUrl('http://example.com'),
        'http://example.com',
      );
    });

    test('normalizes the scheme and host case', () {
      expect(
        SourceRepositories.normalizeUrl('HTTPS://Example.COM/Index.json'),
        'https://example.com/Index.json',
      );
    });
  });

  group('all', () {
    test('returns an empty list when nothing is stored', () {
      expect(SourceRepositories.instance.all, isEmpty);
      expect(SourceRepositories.instance.find('anything'), isNull);
    });

    test('tolerates storage that is not a list', () {
      appdata.settings['comicSourceRepositories'] = 'not a list';
      expect(SourceRepositories.instance.all, isEmpty);

      appdata.settings['comicSourceRepositories'] = null;
      expect(SourceRepositories.instance.all, isEmpty);
    });

    test('skips malformed persisted records and keeps valid ones', () {
      appdata.settings['comicSourceRepositories'] = [
        {
          'id': 'keep-a',
          'name': 'A',
          'url': 'https://a.example.com/index.json',
        },
        'not a map',
        42,
        {'id': 'missing-url', 'name': 'B'},
        {'id': 3, 'name': 'C', 'url': 'https://c.example.com/index.json'},
        {
          'id': 'keep-d',
          'name': 'D',
          'url': 'https://d.example.com/index.json',
        },
        {
          'id': 'null-name',
          'name': null,
          'url': 'https://e.example.com/x.json',
        },
      ];

      final repositories = SourceRepositories.instance.all;
      expect(repositories.map((r) => r.id), ['keep-a', 'keep-d']);
      expect(repositories.map((r) => r.name), ['A', 'D']);
    });

    test('find matches by id and returns null otherwise', () {
      appdata.settings['comicSourceRepositories'] = [
        _repoMap('r1', 'Repo 1', 'https://one.example.com/index.json'),
        _repoMap('r2', 'Repo 2', 'https://two.example.com/index.json'),
      ];

      expect(SourceRepositories.instance.find('r2')?.name, 'Repo 2');
      expect(SourceRepositories.instance.find('missing'), isNull);
      expect(SourceRepositories.instance.find(null), isNull);
    });
  });

  group('originFor/originLabel', () {
    test('originFor tolerates malformed origin storage', () {
      appdata.settings['comicSourceOrigins'] = 'not a map';
      expect(SourceRepositories.instance.originFor('key'), isNull);

      appdata.settings['comicSourceOrigins'] = {'key': 'not a map'};
      expect(SourceRepositories.instance.originFor('key'), isNull);

      appdata.settings['comicSourceOrigins'] = {
        'key': {'url': 'https://example.com'},
      };
      expect(SourceRepositories.instance.originFor('key'), isNull);

      appdata.settings['comicSourceOrigins'] = {
        'key': {'kind': 7},
      };
      expect(SourceRepositories.instance.originFor('key'), isNull);
    });

    test('originFor nulls out non-string optional fields', () {
      appdata.settings['comicSourceOrigins'] = {
        'key': {
          'kind': 'repository',
          'repositoryId': 1,
          'repositoryName': true,
          'url': 2,
        },
      };

      final origin = SourceRepositories.instance.originFor('key')!;
      expect(origin.kind, 'repository');
      expect(origin.repositoryId, isNull);
      expect(origin.repositoryName, isNull);
      expect(origin.url, isNull);
    });

    test(
      'originLabel resolves unlinked, manual, linked and removed origins',
      () {
        appdata.settings['comicSourceRepositories'] = [
          _repoMap('r1', 'Live Repo', 'https://one.example.com/index.json'),
        ];
        appdata.settings['comicSourceOrigins'] = {
          'file': {'kind': 'file', 'url': '/tmp/source.js'},
          'url': {'kind': 'url', 'url': 'https://example.com/source.js'},
          'linked': {
            'kind': 'repository',
            'repositoryId': 'r1',
            'repositoryName': 'Stored Name',
            'url': 'https://one.example.com/source.js',
          },
          'removed': {
            'kind': 'repository',
            'repositoryId': 'gone',
            'repositoryName': 'Old Name',
            'url': 'https://gone.example.com/source.js',
          },
          'removed-no-name': {'kind': 'repository', 'repositoryId': 'gone'},
        };

        final repositories = SourceRepositories.instance;
        expect(repositories.originLabel('missing'), 'No repository linked'.tl);
        expect(repositories.originLabel('file'), 'Imported from file'.tl);
        expect(repositories.originLabel('url'), 'Installed from link'.tl);
        expect(repositories.originLabel('linked'), 'Live Repo');
        expect(
          repositories.originLabel('removed'),
          'Repository removed: @name'.tlParams({'name': 'Old Name'}),
        );
        expect(
          repositories.originLabel('removed-no-name'),
          'Repository removed: @name'.tlParams({'name': ''}),
        );
      },
    );

    test(
      'renaming a repository updates the label but keeps the origin snapshot',
      () {
        appdata.settings['comicSourceRepositories'] = [
          _repoMap('r1', 'Old Name', 'https://one.example.com/index.json'),
        ];
        appdata.settings['comicSourceOrigins'] = {
          'key': {
            'kind': 'repository',
            'repositoryId': 'r1',
            'repositoryName': 'Old Name',
            'url': 'https://one.example.com/source.js',
          },
        };

        expect(SourceRepositories.instance.originLabel('key'), 'Old Name');

        // Renaming the stored repository (what a successful save does) must make
        // the label follow the live record while the origin snapshot stays until
        // the repository is removed.
        appdata.settings['comicSourceRepositories'] = [
          _repoMap('r1', 'New Name', 'https://one.example.com/index.json'),
        ];

        expect(SourceRepositories.instance.originLabel('key'), 'New Name');
        expect(
          SourceRepositories.instance.originFor('key')?.repositoryName,
          'Old Name',
        );
      },
    );
  });

  group('migrate', () {
    test(
      'migrates the legacy catalog url into one repository only once',
      () async {
        appdata.settings['comicSourceListUrl'] =
            'https://legacy.example.com/index.json';

        await SourceRepositories.instance.migrate();

        final repositories = SourceRepositories.instance.all;
        expect(repositories, hasLength(1));
        expect(repositories.single.name, 'legacy.example.com');
        expect(
          repositories.single.url,
          'https://legacy.example.com/index.json',
        );
        expect(appdata.settings['comicSourceRepositoriesMigrated'], isTrue);

        // The user removes the migrated repository; a later run must not recreate
        // it because the migration flag is already set.
        appdata.settings['comicSourceRepositories'] = <Map<String, dynamic>>[];
        await SourceRepositories.instance.migrate();
        expect(SourceRepositories.instance.all, isEmpty);
      },
    );

    test('migration keeps existing repositories', () async {
      appdata.settings['comicSourceRepositories'] = [
        _repoMap('keep', 'Keep', 'https://keep.example.com/index.json'),
      ];
      appdata.settings['comicSourceListUrl'] =
          'https://legacy.example.com/index.json';

      await SourceRepositories.instance.migrate();

      final repositories = SourceRepositories.instance.all;
      expect(repositories, hasLength(1));
      expect(repositories.single.id, 'keep');
      expect(repositories.single.url, 'https://keep.example.com/index.json');
      expect(appdata.settings['comicSourceRepositoriesMigrated'], isTrue);
    });

    test('migration with no legacy url only marks the flag', () async {
      appdata.settings['comicSourceListUrl'] = '   ';

      await SourceRepositories.instance.migrate();

      expect(SourceRepositories.instance.all, isEmpty);
      expect(appdata.settings['comicSourceRepositoriesMigrated'], isTrue);
    });

    test(
      'migration falls back to a default name for a non-url value',
      () async {
        appdata.settings['comicSourceListUrl'] =
            'legacy.example.com/index.json';

        await SourceRepositories.instance.migrate();

        final repositories = SourceRepositories.instance.all;
        expect(repositories, hasLength(1));
        expect(repositories.single.name, 'Migrated repository'.tl);
        expect(repositories.single.url, 'legacy.example.com/index.json');
      },
    );

    test('migration persists repositories and the flag to disk', () async {
      appdata.settings['comicSourceListUrl'] =
          'https://legacy.example.com/index.json';

      await SourceRepositories.instance.migrate();

      final settings = _persistedSettings(dataDir);
      expect(settings['comicSourceRepositories'], hasLength(1));
      expect(
        (settings['comicSourceRepositories'] as List).single['url'],
        'https://legacy.example.com/index.json',
      );
      expect(settings['comicSourceRepositoriesMigrated'], isTrue);
    });
  });

  group('setOrigin', () {
    test('stores and removes origins and notifies listeners', () async {
      var notifications = 0;
      void listener() => notifications++;
      SourceRepositories.instance.addListener(listener);
      addTearDown(() => SourceRepositories.instance.removeListener(listener));
      final revisionBefore = SourceRepositories.instance.revision;

      await SourceRepositories.instance.setOrigin(
        'key',
        const SourceOrigin(kind: 'repository', repositoryId: 'r1', url: 'u'),
      );

      expect(SourceRepositories.instance.originFor('key')?.repositoryId, 'r1');
      expect(SourceRepositories.instance.revision, revisionBefore + 1);
      expect(notifications, 1);

      await SourceRepositories.instance.setOrigin('key', null);

      expect(SourceRepositories.instance.originFor('key'), isNull);
      expect(SourceRepositories.instance.revision, revisionBefore + 2);
      expect(notifications, 2);
    });

    test('replaces malformed origin storage instead of failing', () async {
      appdata.settings['comicSourceOrigins'] = 'not a map';

      await SourceRepositories.instance.setOrigin(
        'key',
        const SourceOrigin(kind: 'file', url: '/tmp/source.js'),
      );

      expect(SourceRepositories.instance.originFor('key')?.kind, 'file');
    });
  });

  group('remove', () {
    test(
      'snapshots the removed repository name and keeps other origins',
      () async {
        appdata.settings['comicSourceRepositories'] = [
          _repoMap('r1', 'Alpha', 'https://one.example.com/index.json'),
          _repoMap('r2', 'Beta', 'https://two.example.com/index.json'),
        ];
        appdata.settings['comicSourceOrigins'] = {
          'alpha': {
            'kind': 'repository',
            'repositoryId': 'r1',
            'repositoryName': 'Stored Alpha',
            'url': 'https://one.example.com/a.js',
          },
          'beta': {
            'kind': 'repository',
            'repositoryId': 'r2',
            'url': 'https://two.example.com/b.js',
          },
          'file': {'kind': 'file', 'url': '/tmp/source.js'},
        };

        final repository = SourceRepository(
          id: 'r1',
          name: 'Alpha',
          url: 'https://one.example.com/index.json',
        );
        var notifications = 0;
        void listener() => notifications++;
        SourceRepositories.instance.addListener(listener);
        addTearDown(() => SourceRepositories.instance.removeListener(listener));

        await SourceRepositories.instance.remove(repository);

        expect(SourceRepositories.instance.all.map((r) => r.id), ['r2']);
        final alpha = SourceRepositories.instance.originFor('alpha')!;
        expect(alpha.repositoryId, 'r1');
        expect(alpha.repositoryName, 'Alpha');
        expect(alpha.url, 'https://one.example.com/a.js');
        expect(
          SourceRepositories.instance.originLabel('alpha'),
          'Repository removed: @name'.tlParams({'name': 'Alpha'}),
        );
        expect(
          SourceRepositories.instance.originFor('beta')?.repositoryName,
          isNull,
        );
        expect(SourceRepositories.instance.originFor('file')?.kind, 'file');
        expect(notifications, 1);

        final settings = _persistedSettings(dataDir);
        expect((settings['comicSourceRepositories'] as List), hasLength(1));
        expect(
          (settings['comicSourceOrigins'] as Map)['alpha']['repositoryName'],
          'Alpha',
        );
      },
    );
  });

  group('link', () {
    final repository = SourceRepository(
      id: 'r1',
      name: 'Repo',
      url: 'https://repo.example.com/index.json',
    );
    const entry = SourceCatalogEntry(
      key: 'source',
      name: 'Source',
      version: '1.0.0',
      url: 'https://repo.example.com/source.js',
    );

    test('links a matching entry to a stored repository', () async {
      appdata.settings['comicSourceRepositories'] = [repository.toJson()];

      await SourceRepositories.instance.link('source', repository, entry);

      final origin = SourceRepositories.instance.originFor('source')!;
      expect(origin.kind, 'repository');
      expect(origin.repositoryId, 'r1');
      expect(origin.repositoryName, 'Repo');
      expect(origin.url, 'https://repo.example.com/source.js');
    });

    test('rejects an entry whose key does not match the source', () async {
      appdata.settings['comicSourceRepositories'] = [repository.toJson()];

      await expectLater(
        SourceRepositories.instance.link('other', repository, entry),
        throwsA('Repository changed. Refresh the list and try again.'.tl),
      );
      expect(SourceRepositories.instance.originFor('other'), isNull);
    });

    test('rejects a repository that is no longer stored', () async {
      await expectLater(
        SourceRepositories.instance.link('source', repository, entry),
        throwsA('Repository changed. Refresh the list and try again.'.tl),
      );
    });

    test('rejects a repository whose stored url changed', () async {
      appdata.settings['comicSourceRepositories'] = [
        _repoMap('r1', 'Repo', 'https://old.example.com/index.json'),
      ];

      await expectLater(
        SourceRepositories.instance.link('source', repository, entry),
        throwsA('Repository changed. Refresh the list and try again.'.tl),
      );
    });

    test('replaces the previous origin for the same source', () async {
      appdata.settings['comicSourceRepositories'] = [
        _repoMap('r1', 'Repo 1', 'https://repo.example.com/index.json'),
        _repoMap('r2', 'Repo 2', 'https://other.example.com/index.json'),
      ];
      appdata.settings['comicSourceOrigins'] = {
        'source': {'kind': 'file', 'url': '/tmp/source.js'},
      };
      const otherEntry = SourceCatalogEntry(
        key: 'source',
        name: 'Source',
        version: '1.0.0',
        url: 'https://other.example.com/source.js',
      );
      final otherRepository = SourceRepository(
        id: 'r2',
        name: 'Repo 2',
        url: 'https://other.example.com/index.json',
      );

      await SourceRepositories.instance.link(
        'source',
        otherRepository,
        otherEntry,
      );

      final origin = SourceRepositories.instance.originFor('source')!;
      expect(origin.kind, 'repository');
      expect(origin.repositoryId, 'r2');
      expect(origin.url, 'https://other.example.com/source.js');
    });
  });

  group('entryFor', () {
    const first = SourceCatalogEntry(
      key: 'source',
      name: 'First',
      version: '1.0.0',
      url: 'https://repo.example.com/first.js',
    );
    const second = SourceCatalogEntry(
      key: 'source',
      name: 'Second',
      version: '1.0.0',
      url: 'https://repo.example.com/second.js',
    );

    test('prefers the previously linked url among multiple variants', () {
      appdata.settings['comicSourceOrigins'] = {
        'source': {
          'kind': 'repository',
          'repositoryId': 'r1',
          'url': 'https://repo.example.com/second.js',
        },
      };

      final entry = SourceRepositories.instance.entryFor(_source('source'), [
        first,
        second,
      ]);

      expect(entry.url, 'https://repo.example.com/second.js');
    });

    test('returns the only candidate when no url was linked before', () {
      final entry = SourceRepositories.instance.entryFor(_source('source'), [
        first,
      ]);

      expect(entry.url, 'https://repo.example.com/first.js');
    });

    test('throws when the source is missing from the catalog', () {
      expect(
        () => SourceRepositories.instance.entryFor(_source('source'), const []),
        throwsA('This source is no longer listed in its repository.'.tl),
      );
    });

    test('throws when multiple variants cannot be disambiguated', () {
      expect(
        () => SourceRepositories.instance.entryFor(_source('source'), [
          first,
          second,
        ]),
        throwsA(
          'Multiple variants found. Choose a source in the repository again.'
              .tl,
        ),
      );
    });
  });

  group('updateUrl', () {
    test('falls back to the source url when no repository is linked', () async {
      final source = _source(
        'source',
        url: 'https://source.example.com/source.js#fragment',
      );

      expect(
        await SourceRepositories.instance.updateUrl(source),
        'https://source.example.com/source.js',
      );
    });

    test('falls back when the linked repository was removed', () async {
      appdata.settings['comicSourceOrigins'] = {
        'source': {
          'kind': 'repository',
          'repositoryId': 'gone',
          'url': 'https://gone.example.com/source.js',
        },
      };
      final source = _source(
        'source',
        url: 'https://source.example.com/source.js',
      );

      expect(
        await SourceRepositories.instance.updateUrl(source),
        'https://source.example.com/source.js',
      );
    });

    test('rejects an invalid source url', () async {
      final source = _source('source', url: 'ftp://source.example.com/s.js');

      await expectLater(
        SourceRepositories.instance.updateUrl(source),
        throwsA('Enter a complete HTTP or HTTPS URL.'.tl),
      );
    });
  });

  group('checkUpdates', () {
    test('skips every source when no repository is stored', () async {
      final result = await SourceRepositories.instance.checkUpdates([
        _source('a'),
        _source('b'),
      ]);

      expect(result.checked, 0);
      expect(result.skipped, 2);
      expect(result.updates, isEmpty);
      expect(result.failures, isEmpty);
    });

    test('ignores stored repositories without linked sources', () async {
      appdata.settings['comicSourceRepositories'] = [
        _repoMap('r1', 'Repo', 'https://one.example.com/index.json'),
      ];

      final result = await SourceRepositories.instance.checkUpdates([
        _source('a'),
        _source('b'),
      ]);

      expect(result.checked, 0);
      expect(result.skipped, 2);
      expect(result.failures, isEmpty);
    });

    test(
      'counts sources whose linked repository no longer exists as skipped',
      () async {
        appdata.settings['comicSourceRepositories'] = [
          _repoMap('r1', 'Repo', 'https://one.example.com/index.json'),
        ];
        appdata.settings['comicSourceOrigins'] = {
          'a': {'kind': 'repository', 'repositoryId': 'gone'},
        };

        final result = await SourceRepositories.instance.checkUpdates([
          _source('a'),
          _source('b'),
        ]);

        expect(result.checked, 0);
        expect(result.skipped, 2);
        expect(result.failures, isEmpty);
      },
    );
  });

  group('save validation', () {
    test('rejects an empty name', () async {
      await expectLater(
        SourceRepositories.instance.save(
          name: '   ',
          url: 'https://example.com/index.json',
        ),
        throwsA('Enter a repository name.'.tl),
      );
    });

    test(
      'rejects an invalid address before looking at stored repositories',
      () async {
        appdata.settings['comicSourceRepositories'] = [
          _repoMap('r1', 'Repo', 'https://example.com/index.json'),
        ];

        await expectLater(
          SourceRepositories.instance.save(
            name: 'Other',
            url: 'ftp://example.com/index.json',
          ),
          throwsA('Enter a complete HTTP or HTTPS URL.'.tl),
        );
      },
    );

    test('rejects an address that duplicates an existing repository', () async {
      appdata.settings['comicSourceRepositories'] = [
        _repoMap('r1', 'Repo', 'https://example.com/index.json#old'),
      ];

      await expectLater(
        SourceRepositories.instance.save(
          name: 'Other',
          url: 'https://example.com/index.json',
        ),
        throwsA('This repository address has already been added.'.tl),
      );
      await expectLater(
        SourceRepositories.instance.save(
          name: 'Other',
          url: 'https://example.com/index.json#new',
        ),
        throwsA('This repository address has already been added.'.tl),
      );
    });

    test('rejects editing a repository onto another stored address', () async {
      appdata.settings['comicSourceRepositories'] = [
        _repoMap('r1', 'First', 'https://one.example.com/index.json'),
        _repoMap('r2', 'Second', 'https://two.example.com/index.json'),
      ];

      await expectLater(
        SourceRepositories.instance.save(
          id: 'r1',
          name: 'Renamed First',
          url: 'https://two.example.com/index.json',
        ),
        throwsA('This repository address has already been added.'.tl),
      );
      // The rejected edit must not have modified the stored records.
      expect(
        SourceRepositories.instance.find('r1')?.url,
        'https://one.example.com/index.json',
      );
    });
  });

  test('SourceRepository and SourceOrigin round-trip through json', () {
    const repository = SourceRepository(
      id: 'r1',
      name: 'Repo',
      url: 'https://example.com/index.json',
    );
    expect(repository.toJson(), {
      'id': 'r1',
      'name': 'Repo',
      'url': 'https://example.com/index.json',
    });

    const origin = SourceOrigin(
      kind: 'repository',
      repositoryId: 'r1',
      repositoryName: 'Repo',
      url: 'https://example.com/source.js',
    );
    expect(origin.toJson(), {
      'kind': 'repository',
      'repositoryId': 'r1',
      'repositoryName': 'Repo',
      'url': 'https://example.com/source.js',
    });
  });
}

Map<String, dynamic> _repoMap(String id, String name, String url) {
  return SourceRepository(id: id, name: name, url: url).toJson();
}

Map<String, dynamic> _persistedSettings(Directory dataDir) {
  final file = File('${dataDir.path}/appdata.json');
  final decoded = jsonDecode(file.readAsStringSync()) as Map;
  return Map<String, dynamic>.from(decoded['settings'] as Map);
}

ComicSource _source(
  String key, {
  String url = 'https://example.com/source.js',
}) {
  return ComicSource(
    'Source $key',
    key,
    null,
    null,
    null,
    null,
    const [],
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    '$key.js',
    url,
    '1.0.0',
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    false,
    false,
    null,
    null,
  );
}
