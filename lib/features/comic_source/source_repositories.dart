import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/extensions.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/network/app_dio.dart';

import 'parser.dart';
import 'source.dart';

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
  final List<String> failures;
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
    super.notifyListeners();
  }

  List<SourceRepository> get all {
    final records = appdata.settings['comicSourceRepositories'];
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

  SourceOrigin? originFor(String key) {
    final origins = appdata.settings['comicSourceOrigins'];
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

  Future<void> migrate() async {
    await appdata.ensureInit();
    if (appdata.settings['comicSourceRepositoriesMigrated'] == true) return;
    final legacy =
        appdata.settings['comicSourceListUrl']?.toString().trim() ?? '';
    if (all.isEmpty && legacy.isNotEmpty) {
      appdata.settings['comicSourceRepositories'] = [
        SourceRepository(
          id: const Uuid().v4(),
          name: Uri.tryParse(legacy)?.host.isNotEmpty == true
              ? Uri.parse(legacy).host
              : 'Migrated repository'.tl,
          url: legacy,
        ).toJson(),
      ];
    }
    appdata.settings['comicSourceRepositoriesMigrated'] = true;
    await appdata.saveData(false);
  }

  static String normalizeUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw 'Enter a complete HTTP or HTTPS URL.'.tl;
    }
    return uri.removeFragment().toString();
  }

  Future<SourceCatalog> load(
    SourceRepository repository, {
    Dio? client,
    CancelToken? cancelToken,
  }) async {
    final base = Uri.parse(normalizeUrl(repository.url));
    final dio = client ?? _client ?? debugCreateDio?.call() ?? AppDio();
    final ownsClient = client == null && _client == null;
    late Response<String> response;
    try {
      response = await dio.get<String>(
        base.toString(),
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.plain,
          headers: {'cache-time': 'no'},
        ),
      );
    } finally {
      if (ownsClient) dio.close();
    }
    if (response.statusCode != 200) throw 'Unable to load repository.'.tl;
    return parseCatalog(response.data!, baseUrl: response.realUri.toString());
  }

  static SourceCatalog parseCatalog(String contents, {String? baseUrl}) {
    final base = baseUrl == null ? null : Uri.parse(normalizeUrl(baseUrl));
    dynamic json;
    try {
      json = jsonDecode(contents.replaceFirst('\uFEFF', ''));
    } catch (_) {
      throw 'The address must return a source list in JSON format.'.tl;
    }
    if (json is! List) {
      throw 'The address must return a source list in JSON format.'.tl;
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
      throw 'The repository contains no usable source entries.'.tl;
    }
    return SourceCatalog(entries, skipped);
  }

  Future<SourceRepository> save({
    String? id,
    required String name,
    required String url,
    String? catalogContents,
  }) async {
    name = name.trim();
    url = normalizeUrl(url);
    if (name.isEmpty) throw 'Enter a repository name.'.tl;
    void validateDuplicate() {
      if (all.any(
        (r) =>
            r.id != id &&
            Uri.tryParse(r.url)?.removeFragment().toString() == url,
      )) {
        throw 'This repository address has already been added.'.tl;
      }
    }

    validateDuplicate();
    final repository = SourceRepository(
      id: id ?? const Uuid().v4(),
      name: name,
      url: url,
    );
    if (catalogContents == null) {
      await load(repository);
    } else {
      parseCatalog(catalogContents, baseUrl: url);
    }
    validateDuplicate();
    final repositories = all;
    final index = repositories.indexWhere((r) => r.id == id);
    if (id != null && index < 0) throw 'Repository no longer exists.'.tl;
    if (index < 0) {
      repositories.add(repository);
    } else {
      repositories[index] = repository;
    }
    appdata.settings['comicSourceRepositories'] = repositories
        .map((r) => r.toJson())
        .toList();
    await appdata.saveData();
    notifyListeners();
    return repository;
  }

  Future<void> remove(SourceRepository repository) async {
    final currentOrigins = appdata.settings['comicSourceOrigins'];
    if (currentOrigins is Map) {
      appdata.settings['comicSourceOrigins'] = {
        for (final entry in currentOrigins.entries)
          entry.key:
              entry.value is Map && entry.value['repositoryId'] == repository.id
              ? {...entry.value as Map, 'repositoryName': repository.name}
              : entry.value,
      };
    }
    appdata.settings['comicSourceRepositories'] = all
        .where((r) => r.id != repository.id)
        .map((r) => r.toJson())
        .toList();
    await appdata.saveData();
    notifyListeners();
  }

  Future<void> setOrigin(String key, SourceOrigin? origin) async {
    final current = appdata.settings['comicSourceOrigins'];
    final origins = current is Map
        ? Map<String, dynamic>.from(current)
        : <String, dynamic>{};
    if (origin == null) {
      origins.remove(key);
    } else {
      origins[key] = origin.toJson();
    }
    appdata.settings['comicSourceOrigins'] = origins;
    await appdata.saveData();
    notifyListeners();
  }

  Future<void> link(
    String key,
    SourceRepository repository,
    SourceCatalogEntry entry,
  ) async {
    if (entry.key != key || find(repository.id)?.url != repository.url) {
      throw 'Repository changed. Refresh the list and try again.'.tl;
    }
    await setOrigin(
      key,
      SourceOrigin(
        kind: 'repository',
        repositoryId: repository.id,
        repositoryName: repository.name,
        url: entry.url,
      ),
    );
  }

  SourceCatalogEntry entryFor(
    ComicSource source,
    List<SourceCatalogEntry> entries,
  ) {
    final candidates = entries.where((e) => e.key == source.key).toList();
    final previousUrl = originFor(source.key)?.url;
    final exact = candidates.firstWhereOrNull((e) => e.url == previousUrl);
    if (exact != null) return exact;
    if (candidates.length == 1) return candidates.single;
    throw (candidates.isEmpty
            ? 'This source is no longer listed in its repository.'
            : 'Multiple variants found. Choose a source in the repository again.')
        .tl;
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

  Future<SourceUpdateCheck> checkUpdates(List<ComicSource> sources) async {
    final repositories = all;
    final updates = <String, String>{};
    final failures = <String>[];
    var checked = 0;
    var skipped = sources
        .where((s) => find(originFor(s.key)?.repositoryId) == null)
        .length;
    // A failed repository does not prevent checking other repositories.
    for (final repository in repositories) {
      final linked = sources
          .where((s) => originFor(s.key)?.repositoryId == repository.id)
          .toList();
      if (linked.isEmpty) continue;
      try {
        final catalog = await load(repository);
        final entries = catalog.entries;
        if (find(repository.id)?.url != repository.url) {
          failures.add(
            '${repository.name}: ${'Repository changed. Refresh the list and try again.'.tl}',
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
            failures.add('${repository.name} / ${source.name}: $error');
          }
        }
      } catch (error) {
        skipped += linked.length;
        failures.add('${repository.name}: $error');
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
