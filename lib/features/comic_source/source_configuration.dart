import 'dart:convert';

import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';

import 'source.dart';
import 'source_repositories.dart';
import 'source_mutation_failure.dart';
import 'source_transaction_journal.dart';

Future<void> finishSourceStorageRecovery(
  String path,
  Future<void> Function() action,
) => appdata.runPersistenceMaintenance((admittedPath) {
  if (admittedPath != path) {
    throw StateError('Source recovery belongs to another data directory');
  }
  return action();
});

/// Owns only the settings published by one source mutation. Capture the old
/// values at the settings queue head, after asynchronous source initialization.
class SourceConfigurationChange {
  SourceConfigurationChange.register(
    ComicSource source, {
    SourceOrigin? origin,
    required String dataPath,
  }) : _key = source.key,
       _path = dataPath,
       _pages = (() => _pagesFor([source])),
       _remove = false,
       _changeOrigin = origin != null,
       _expectedOrigin = _originSnapshot(source.key),
       _origin = origin?.toJson();

  SourceConfigurationChange.remove(
    String sourceKey, {
    required Iterable<ComicSource> Function() remainingSources,
    required String dataPath,
  }) : _key = sourceKey,
       _path = dataPath,
       _pages = (() => _pagesFor(remainingSources())),
       _remove = true,
       _changeOrigin = true,
       _expectedOrigin = _originSnapshot(sourceKey),
       _origin = null;

  final String _key;
  final String _path;
  final Map<String, List<String>> Function() _pages;
  final bool _remove;
  final bool _changeOrigin;
  final Map<String, dynamic>? _origin;
  final Object? _expectedOrigin;
  final _before = <String, Object?>{};
  final _after = <String, Object?>{};
  Object? _originsBefore;
  Object? _originsAfter;
  bool _originEdited = false;

  static Object? _originSnapshot(String key) {
    final origins = appdata.settings['comicSourceOrigins'];
    return _copy(origins is Map ? origins[key] : null);
  }

  static Map<String, List<String>> _pagesFor(Iterable<ComicSource> sources) {
    final all = sources.toList();
    return {
      'explore_pages': [
        for (final source in all)
          ...source.explorePages.map((page) => page.title),
      ],
      'categories': [
        for (final source in all)
          if (source.categoryData != null) source.categoryData!.key,
      ],
      'favorites': [
        for (final source in all)
          if (source.favoriteData != null) source.favoriteData!.key,
      ],
      'searchSources': [
        for (final source in all)
          if (source.searchPageData != null) source.key,
      ],
    };
  }

  void _checkPath() {
    if (App.dataPath != _path) {
      throw StateError(
        'Source configuration belongs to a different data directory',
      );
    }
  }

  Future<void> apply({SourceTransactionJournal? transaction}) async {
    try {
      await appdata.updateSettings(
        (draft) {
          _checkPath();
          final pages = _pages();
          final origins = draft['comicSourceOrigins'];
          if (_changeOrigin &&
              !_same(origins is Map ? origins[_key] : null, _expectedOrigin)) {
            throw StateError(
              'Source origin changed while the operation was preparing',
            );
          }
          for (final entry in pages.entries) {
            final previous = draft[entry.key];
            final current = previous is List
                ? List<Object?>.of(previous)
                : <Object?>[];
            final next = _remove
                ? current.where(entry.value.contains).toSet().toList()
                : {...current, ...entry.value}.toList();
            if (_same(previous, next)) continue;
            _before[entry.key] = _copy(previous);
            _after[entry.key] = _copy(next);
            draft[entry.key] = next;
          }
          if (_changeOrigin) {
            final previous = draft['comicSourceOrigins'];
            final origins = previous is Map
                ? Map<String, dynamic>.from(previous)
                : <String, dynamic>{};
            if (_origin == null) {
              origins.remove(_key);
            } else {
              origins[_key] = _origin;
            }
            if (!_same(previous, origins)) {
              _originsBefore = _copy(previous);
              _originsAfter = _copy(origins);
              _originEdited = true;
              draft['comicSourceOrigins'] = origins;
            }
          }
        },
        beforePersist: transaction == null
            ? null
            : (contents) {
                transaction.recordSettings(contents, {
                  'fields': {
                    for (final entry in _before.entries)
                      entry.key: {
                        'before': entry.value,
                        'after': _after[entry.key],
                      },
                  },
                  'origin': _originEdited
                      ? {
                          'key': _key,
                          'before': _originsBefore,
                          'after': _originsAfter,
                        }
                      : null,
                });
                return null;
              },
      );
    } finally {
      if (_before.isNotEmpty || _originEdited) {
        SourceRepositories.instance.notifyListeners();
      }
    }
  }

  /// A later edit owns its value. Report conflicts after restoring independent
  /// fields instead of overwriting the newer configuration or losing errors.
  Future<void> rollback() async {
    if (_before.isEmpty && !_originEdited) return;
    final conflicts = <String>[];
    final failures = <SourceMutationError>[];
    try {
      await appdata.updateSettings((draft) {
        _checkPath();
        for (final entry in _before.entries) {
          final current = draft[entry.key];
          if (_same(current, _after[entry.key])) {
            draft[entry.key] = _copy(entry.value);
          } else if (!_same(current, entry.value)) {
            conflicts.add(entry.key);
          }
        }
        if (_originEdited) {
          final current = draft['comicSourceOrigins'];
          if (_same(current, _originsAfter)) {
            draft['comicSourceOrigins'] = _copy(_originsBefore);
          } else if (!_same(current, _originsBefore)) {
            final before = _originsBefore is Map
                ? _originsBefore as Map
                : const {};
            final after = _originsAfter as Map;
            final origins = current is Map
                ? Map<String, dynamic>.from(current)
                : <String, dynamic>{};
            final matchesAfter =
                origins.containsKey(_key) == after.containsKey(_key) &&
                _same(origins[_key], after[_key]);
            final matchesBefore =
                origins.containsKey(_key) == before.containsKey(_key) &&
                _same(origins[_key], before[_key]);
            if (matchesAfter) {
              if (before.containsKey(_key)) {
                origins[_key] = _copy(before[_key]);
              } else {
                origins.remove(_key);
              }
              draft['comicSourceOrigins'] = origins;
            } else if (!matchesBefore) {
              conflicts.add('comicSourceOrigins/$_key');
            }
          }
        }
      }, sync: false);
    } catch (error, stack) {
      failures.add((
        stage: 'persist source configuration recovery',
        error: error,
        stack: stack,
      ));
    } finally {
      SourceRepositories.instance.notifyListeners();
    }
    if (conflicts.isNotEmpty) {
      failures.add((
        stage: 'preserve newer source configuration',
        error: SourceConfigurationConflict(conflicts),
        stack: StackTrace.current,
      ));
    }
    if (failures.length == 1) {
      Error.throwWithStackTrace(failures.single.error, failures.single.stack);
    }
    if (failures.isNotEmpty) {
      throw SourceMutationFailure(
        state: SourceMutationState.recoveryRequired,
        failures: failures,
      );
    }
  }

  static bool _same(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);
  static Object? _copy(Object? value) => jsonDecode(jsonEncode(value));
}

class SourceConfigurationConflict implements Exception {
  SourceConfigurationConflict(Iterable<String> fields)
    : fields = List.unmodifiable(fields);
  final List<String> fields;
  @override
  String toString() =>
      'Source recovery preserved newer configuration: ${fields.join(', ')}';
}
