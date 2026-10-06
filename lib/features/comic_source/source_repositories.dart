import 'source_failure.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/extensions.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/network/app_dio.dart';

import 'parser.dart';
import 'source.dart';
import 'source_text_request.dart';

class SourceRepository {
  const SourceRepository({
    required this.id,
    required this.name,
    required this.url,
  });

  final String id;
  final String name;
  final String url;

  Map<String, String> toJson() => {'id': id, 'name': name, 'url': url};
}

class SourceCatalogEntry {
  const SourceCatalogEntry({
    required this.key,
    required this.name,
    required this.version,
    required this.url,
    this.description = '',
  });

  final String key;
  final String name;
  final String version;
  final String url;
  final String description;
}

/// A loaded catalog. Invalid entries are skipped and reported instead of
/// making the whole repository unusable.
class SourceCatalog {
  const SourceCatalog(this.entries, this.skipped);

  final List<SourceCatalogEntry> entries;

  /// Labels of the entries that were skipped, in catalog order.
  final List<String> skipped;
}

class SourceOrigin {
  const SourceOrigin({
    required this.kind,
    this.repositoryId,
    this.repositoryName,
    this.url,
  });

  final String kind;
  final String? repositoryId;
  final String? repositoryName;
  final String? url;

  Map<String, String?> toJson() => {
    'kind': kind,
    'repositoryId': repositoryId,
    'repositoryName': repositoryName,
    'url': url,
  };
}

class SourceUpdateCheck {
  const SourceUpdateCheck({
    required this.updates,
    required this.failures,
    required this.checked,
    required this.skipped,
  });

  final Map<String, String> updates;
  final List<SourceCheckFailure> failures;
  final int checked;
  final int skipped;
}

/// Repository preferences live alongside the existing source and app backups.
/// Catalogs are loaded per operation, so editing a URL never leaves a stale base.
class SourceRepositories extends ChangeNotifier {
  SourceRepositories._() : _client = null;

  @visibleForTesting
  SourceRepositories.forTesting(Dio client) : _client = client;

  @visibleForTesting
  static Dio Function()? debugCreateDio;

  final Dio? _client;
  static final instance = SourceRepositories._();
  int revision = 0;

  @override
  void notifyListeners() {
    revision++;
    AppDataOperations.instance.publish(super.notifyListeners);
  }

  List<SourceRepository> get all => _repositories(appdata.settings);

  List<SourceRepository> _repositories(Settings settings) {
    final records = settings['comicSourceRepositories'];
    if (records is! List) return [];
    return records
        .whereType<Map>()
        .where(
          (record) =>
              record['id'] is String &&
              record['name'] is String &&
              record['url'] is String,
        )
        .map(
          (record) => SourceRepository(
            id: record['id'],
            name: record['name'],
            url: record['url'],
          ),
        )
        .toList();
  }

  SourceRepository? find(String? id) => all.firstWhereOrNull((r) => r.id == id);

  SourceOrigin? originFor(String key) => _originFor(appdata.settings, key);

  SourceOrigin? _originFor(Settings settings, String key) {
    final origins = settings['comicSourceOrigins'];
    final record = origins is Map ? origins[key] : null;
    if (record is! Map || record['kind'] is! String) return null;
    return SourceOrigin(
      kind: record['kind'],
      repositoryId: record['repositoryId'] is String
          ? record['repositoryId']
          : null,
      repositoryName: record['repositoryName'] is String
          ? record['repositoryName']
          : null,
      url: record['url'] is String ? record['url'] : null,
    );
  }

  String originLabel(String key) {
    final origin = originFor(key);
    if (origin == null) return 'No repository linked'.tl;
    if (origin.kind == 'file') return 'Imported from file'.tl;
    if (origin.kind == 'url') return 'Installed from link'.tl;
    final repository = find(origin.repositoryId);
    return repository?.name ??
        'Repository removed: @name'.tlParams({
          'name': origin.repositoryName ?? '',
        });
  }

  Future<void>? _migration;
  bool _migrationNeedsSave = false;

  Future<void> migrate() async {
    // Do not hold access while waiting for startup to initialize settings.
    await appdata.ensureInit();
    await AppDataOperations.instance.access(
      () => _migration ??= _migrate().whenComplete(() => _migration = null),
    );
  }

  Future<void> _migrate() async {
    try {
      await appdata.updateSettings(
        (draft) {
          if (draft['comicSourceRepositoriesMigrated'] == true) return;
          final legacy = draft['comicSourceListUrl']?.toString().trim() ?? '';
          if (_repositories(draft).isEmpty && legacy.isNotEmpty) {
            draft['comicSourceRepositories'] = [
              SourceRepository(
                id: const Uuid().v4(),
                name: Uri.tryParse(legacy)?.host.isNotEmpty == true
                    ? Uri.parse(legacy).host
                    : 'Migrated repository'.tl,
                url: legacy,
              ).toJson(),
            ];
          }
          draft['comicSourceRepositoriesMigrated'] = true;
        },
        sync: false,
        persistIfUnchanged: _migrationNeedsSave,
      );
      _migrationNeedsSave = false;
    } catch (_) {
      // Published state may already be durable in one of the settings files.
      // Retain it and force the next attempt to finish persistence.
      _migrationNeedsSave = true;
      rethrow;
    }
  }

  Future<T> _edit<T>(T Function(Settings) change) async {
    var edited = false;
    try {
      return await appdata.updateSettings((draft) {
        final result = change(draft);
        edited = true;
        return result;
      });
    } finally {
      // Also invalidate consumers after a partial write; they must not retain
      // results derived from the old settings. Never lend admission to them.
      if (edited) notifyListeners();
    }
  }

  static String normalizeUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw const SourceFailure(SourceFailureCode.invalidUrl);
    }
    return uri.removeFragment().toString();
  }

  Future<SourceCatalog> load(
    SourceRepository repository, {
    Dio? client,
    Dio Function()? createClient,
    CancelToken? cancelToken,
  }) async {
    final base = Uri.parse(normalizeUrl(repository.url));
    final response = await readSourceText(
      base.toString(),
      client: client ?? _client,
      createClient: createClient ?? debugCreateDio,
      cancelToken: cancelToken,
    );
    if (response.statusCode != 200) {
      throw const SourceFailure(SourceFailureCode.unavailableRepository);
    }
    return parseCatalog(response.data!, baseUrl: response.realUri.toString());
  }

  static SourceCatalog parseCatalog(String contents, {String? baseUrl}) {
    final base = baseUrl == null ? null : Uri.parse(normalizeUrl(baseUrl));
    dynamic json;
    try {
      json = jsonDecode(contents.replaceFirst('\uFEFF', ''));
    } catch (error, stack) {
      throw SourceFailure(
        SourceFailureCode.invalidCatalog,
        cause: error,
        stackTrace: stack,
      );
    }
    if (json is! List) {
      throw const SourceFailure(SourceFailureCode.invalidCatalog);
    }
    final entries = <SourceCatalogEntry>[];
    final skipped = <String>[];
    for (var index = 0; index < json.length; index++) {
      final record = json[index];
      final key = record is Map ? record['key'] : null;
      final label = key is String && key.trim().isNotEmpty
          ? key.trim()
          : '#${index + 1}';
      if (record is! Map ||
          key is! String ||
          record['name'] is! String ||
          record['version'] is! String ||
          !RegExp(r'^\w+$').hasMatch(key) ||
          !RegExp(
            r'^\d+\.\d+\.\d+(?:[.\-].+)?$',
          ).hasMatch(record['version'] as String)) {
        skipped.add(label);
        continue;
      }
      final target =
          record['url'] is String && (record['url'] as String).trim().isNotEmpty
          ? record['url'] as String
          : record['fileName'];
      if (target is! String || target.trim().isEmpty) {
        skipped.add(label);
        continue;
      }
      try {
        entries.add(
          SourceCatalogEntry(
            key: key,
            name: record['name'] as String,
            version: record['version'] as String,
            url: normalizeUrl(
              base == null
                  ? target.trim()
                  : base.resolve(target.trim()).toString(),
            ),
            description: record['description']?.toString() ?? '',
          ),
        );
      } catch (_) {
        skipped.add(label);
      }
    }
    if (entries.isEmpty && skipped.isNotEmpty) {
      throw const SourceFailure(SourceFailureCode.emptyCatalog);
    }
    return SourceCatalog(entries, skipped);
  }

  SourceRepositorySave prepareSave({
    String? id,
    required String name,
    required String url,
    String? catalogContents,
  }) => SourceRepositorySave._(
    this,
    id: id,
    name: name,
    url: url,
    catalogContents: catalogContents,
  );

  Future<SourceRepository> save({
    String? id,
    required String name,
    required String url,
    String? catalogContents,
  }) async => prepareSave(
    id: id,
    name: name,
    url: url,
    catalogContents: catalogContents,
  ).save();

  Future<void> remove(SourceRepository repository) => _edit((draft) {
    final repositories = _repositories(draft);
    final current = repositories.firstWhereOrNull((r) => r.id == repository.id);
    if (current != null && !_sameRepository(current, repository)) {
      throw const SourceFailure(SourceFailureCode.repositoryChanged);
    }
    final currentOrigins = draft['comicSourceOrigins'];
    if (currentOrigins is Map) {
      draft['comicSourceOrigins'] = {
        for (final entry in currentOrigins.entries)
          entry.key:
              entry.value is Map && entry.value['repositoryId'] == repository.id
              ? {...entry.value as Map, 'repositoryName': repository.name}
              : entry.value,
      };
    }
    draft['comicSourceRepositories'] = repositories
        .where((r) => r.id != repository.id)
        .map((r) => r.toJson())
        .toList();
  });

  void _setOrigin(Settings draft, String key, SourceOrigin? origin) {
    final current = draft['comicSourceOrigins'];
    final origins = current is Map
        ? Map<String, dynamic>.from(current)
        : <String, dynamic>{};
    if (origin == null) {
      origins.remove(key);
    } else {
      origins[key] = origin.toJson();
    }
    draft['comicSourceOrigins'] = origins;
  }

  Future<void> setOrigin(String key, SourceOrigin? origin) =>
      _edit((draft) => _setOrigin(draft, key, origin));

  Future<void> unlink(String key, SourceOrigin expected) => _edit((draft) {
    final current = _originFor(draft, key);
    if (current != null &&
        jsonEncode(current.toJson()) != jsonEncode(expected.toJson())) {
      throw const SourceFailure(SourceFailureCode.repositoryChanged);
    }
    _setOrigin(draft, key, null);
  });

  Future<void> link(
    String key,
    SourceRepository repository,
    SourceCatalogEntry entry,
  ) => _edit((draft) {
    final current = _repositories(
      draft,
    ).firstWhereOrNull((r) => r.id == repository.id);
    if (entry.key != key || current?.url != repository.url) {
      throw const SourceFailure(SourceFailureCode.repositoryChanged);
    }
    _setOrigin(
      draft,
      key,
      SourceOrigin(
        kind: 'repository',
        repositoryId: repository.id,
        repositoryName: current!.name,
        url: entry.url,
      ),
    );
  });

  SourceCatalogEntry entryFor(
    ComicSource source,
    List<SourceCatalogEntry> entries,
  ) {
    final candidates = entries.where((e) => e.key == source.key).toList();
    final previousUrl = originFor(source.key)?.url;
    final exact = candidates.firstWhereOrNull((e) => e.url == previousUrl);
    if (exact != null) return exact;
    if (candidates.length == 1) return candidates.single;
    throw SourceFailure(
      candidates.isEmpty
          ? SourceFailureCode.missingSource
          : SourceFailureCode.ambiguousSource,
    );
  }

  Future<String> updateUrl(
    ComicSource source, {
    Dio? client,
    CancelToken? cancelToken,
  }) async {
    final repository = find(originFor(source.key)?.repositoryId);
    if (repository == null) return normalizeUrl(source.url);
    final catalog = await load(
      repository,
      client: client,
      cancelToken: cancelToken,
    );
    return entryFor(source, catalog.entries).url;
  }

  Future<SourceUpdateCheck> checkUpdates(
    List<ComicSource> sources, {
    Dio? client,
    CancelToken? cancelToken,
  }) async {
    final repositories = all;
    final updates = <String, String>{};
    final failures = <SourceCheckFailure>[];
    var checked = 0;
    var skipped = sources
        .where((s) => find(originFor(s.key)?.repositoryId) == null)
        .length;
    // A failed repository does not prevent checking other repositories.
    for (final repository in repositories) {
      if (cancelToken?.isCancelled == true) {
        throw const SourceFailure(SourceFailureCode.cancelled);
      }
      final linked = sources
          .where((s) => originFor(s.key)?.repositoryId == repository.id)
          .toList();
      if (linked.isEmpty) continue;
      try {
        final catalog = await load(
          repository,
          client: client,
          cancelToken: cancelToken,
        );
        if (cancelToken?.isCancelled == true) {
          throw const SourceFailure(SourceFailureCode.cancelled);
        }
        final entries = catalog.entries;
        if (find(repository.id)?.url != repository.url) {
          failures.add(
            SourceCheckFailure(
              const SourceFailure(SourceFailureCode.repositoryChanged),
              repository: repository.name,
            ),
          );
          skipped += linked.length;
          continue;
        }
        for (final source in linked) {
          if (originFor(source.key)?.repositoryId != repository.id) {
            skipped++;
            continue;
          }
          try {
            final entry = entryFor(source, entries);
            if (compareSemVer(entry.version, source.version)) {
              updates[source.key] = entry.version;
            }
            checked++;
          } catch (error) {
            skipped++;
            failures.add(
              SourceCheckFailure(
                error,
                repository: repository.name,
                source: source.name,
              ),
            );
          }
        }
      } catch (error) {
        if (cancelToken?.isCancelled == true) {
          throw const SourceFailure(SourceFailureCode.cancelled);
        }
        skipped += linked.length;
        failures.add(SourceCheckFailure(error, repository: repository.name));
      }
    }
    return SourceUpdateCheck(
      updates: updates,
      failures: failures,
      checked: checked,
      skipped: skipped,
    );
  }
}

bool _sameRepository(SourceRepository? a, SourceRepository? b) =>
    a?.id == b?.id && a?.name == b?.name && a?.url == b?.url;

/// A fixed assignment with one successful catalog validation. Retrying a
/// partially saved creation reuses its ID and never overwrites later edits.
class SourceRepositorySave {
  SourceRepositorySave._(
    this._store, {
    String? id,
    required String name,
    required String url,
    String? catalogContents,
  }) : _editing = id != null,
       _previous = id == null ? null : _store.find(id),
       _path = App.dataPath,
       _catalogContents = catalogContents,
       repository = SourceRepository(
         id: id ?? const Uuid().v4(),
         name: name.trim(),
         url: SourceRepositories.normalizeUrl(url),
       ) {
    if (repository.name.isEmpty) {
      throw const SourceFailure(SourceFailureCode.missingName);
    }
  }

  final SourceRepositories _store;
  final bool _editing;
  final SourceRepository? _previous;
  final String _path;
  final String? _catalogContents;
  final SourceRepository repository;
  Future<void>? _validation;
  bool _published = false;

  void _validateTarget(List<SourceRepository> repositories) {
    if (App.dataPath != _path) {
      throw const SourceFailure(SourceFailureCode.repositoryChanged);
    }
    final current = repositories.firstWhereOrNull((r) => r.id == repository.id);
    if (_published) {
      if (current == null) {
        throw const SourceFailure(SourceFailureCode.missingRepository);
      }
      if (!_sameRepository(current, repository)) {
        throw const SourceFailure(SourceFailureCode.repositoryChanged);
      }
    } else if (_editing) {
      if (current == null) {
        throw const SourceFailure(SourceFailureCode.missingRepository);
      }
      if (!_sameRepository(current, _previous)) {
        throw const SourceFailure(SourceFailureCode.repositoryChanged);
      }
    }
    if (repositories.any(
      (r) =>
          r.id != repository.id &&
          Uri.tryParse(r.url)?.removeFragment().toString() == repository.url,
    )) {
      throw const SourceFailure(SourceFailureCode.duplicateRepository);
    }
  }

  Future<void> validate() => _validation ??=
      Future<void>.sync(() async {
        _validateTarget(_store.all);
        if (_catalogContents == null) {
          await _store.load(repository);
        } else {
          SourceRepositories.parseCatalog(
            _catalogContents,
            baseUrl: repository.url,
          );
        }
      }).catchError((Object error, StackTrace stack) {
        _validation = null;
        Error.throwWithStackTrace(error, stack);
      });

  Future<SourceRepository> save() async {
    await validate();
    try {
      return await _store._edit((draft) {
        final repositories = _store._repositories(draft);
        _validateTarget(repositories);
        final index = repositories.indexWhere((r) => r.id == repository.id);
        if (index < 0) {
          repositories.add(repository);
        } else {
          repositories[index] = repository;
        }
        draft['comicSourceRepositories'] = repositories
            .map((r) => r.toJson())
            .toList();
        return repository;
      });
    } finally {
      if (_sameRepository(_store.find(repository.id), repository)) {
        _published = true;
      }
    }
  }
}
