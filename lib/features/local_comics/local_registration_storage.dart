import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/favorites/favorites_api.dart';
import 'package:venera_next/features/favorites/favorites_repository.dart';
import 'package:venera_next/foundation/persistence_failure.dart';
import 'package:venera_next/foundation/comic_type.dart';

import 'local_comic_model.dart';
import 'local_repository.dart';

String findUnusedLocalComicId(
  Database localDatabase,
  ComicType type, {
  String? favoritesPath,
}) {
  final explicitFavorites = favoritesPath != null;
  if (favoritesPath == null) {
    final filename =
        localDatabase
                .select('PRAGMA database_list;')
                .singleWhere((row) => row['name'] == 'main')['file']
            as String;
    if (filename.isNotEmpty) {
      favoritesPath = path.join(path.dirname(filename), 'local_favorite.db');
    }
  }
  final local = LocalRepository(localDatabase);
  if (favoritesPath == null) {
    return local.findValidId(type);
  }
  final kind = FileSystemEntity.typeSync(favoritesPath);
  if (kind == FileSystemEntityType.notFound && !explicitFavorites) {
    return local.findValidId(type);
  }
  if (kind != FileSystemEntityType.file) {
    throw StateError('Favorites database is missing or unavailable');
  }
  // A migrated favorite may outlive local.db. Read the original store even
  // without a selected folder or initialized UI; never create or repair it here.
  final favorites = sqlite3.open(favoritesPath, mode: OpenMode.readOnly);
  try {
    return local.findValidId(
      type,
      reservedIds: FavoritesRepository(favorites).comicIds(type.value),
    );
  } finally {
    favorites.dispose();
  }
}

/// A single SQLite commit owns both records. The caller holds data admission,
/// local write ownership and the favorites mutation queue. Publication follows
/// commit and must never compensate by deleting either record afterwards.
void registerLocalComicRecords({
  required Database localDatabase,
  required LocalComic comic,
  required String id,
  required String favoritesPath,
  required String folder,
  required FavoriteItem favorite,
  required String translatedTags,
  required bool append,
}) {
  var attached = false;
  var began = false;
  var commitAttempted = false;
  var state = PersistenceCommitState.notCommitted;
  Object? cause;
  StackTrace? causeStack;
  final cleanup = <({Object error, StackTrace stackTrace})>[];
  try {
    if (!localDatabase.autocommit) {
      throw StateError('Comic registration requires its own transaction');
    }
    localDatabase.execute('ATTACH DATABASE ? AS registration_favorites;', [
      favoritesPath,
    ]);
    attached = true;
    // Attached databases are crash-atomic together only with on-disk rollback
    // journals. Refuse a different mode instead of silently weakening that rule.
    for (final schema in ['main', 'registration_favorites']) {
      final mode = localDatabase
          .select('PRAGMA $schema.journal_mode;')
          .single
          .values
          .single;
      if (!const ['delete', 'truncate', 'persist'].contains(mode)) {
        throw StateError(
          'Comic registration requires rollback journals: $schema=$mode',
        );
      }
    }
    began = true;
    localDatabase.execute('BEGIN IMMEDIATE;');
    if (favorite.id != id || favorite.type != comic.comicType) {
      throw ArgumentError('Local and favorite identities must match');
    }
    final local = LocalRepository(localDatabase);
    if (local.find(id, comic.comicType) != null) {
      throw StateError('Comic registration identity is already in use');
    }
    final favorites = FavoritesRepository(localDatabase);
    if (favorites.containsIdentity(
      id,
      comic.comicType.value,
      schema: 'registration_favorites',
    )) {
      throw StateError('Favorite registration identity is already in use');
    }
    local.add(comic, id);
    final added = favorites.addComic(
      folder,
      favorite,
      translatedTags: translatedTags,
      append: append,
      schema: 'registration_favorites',
    );
    if (!added) {
      throw StateError('Favorite registration identity is already in use');
    }
    commitAttempted = true;
    localDatabase.execute('COMMIT;');
    state = PersistenceCommitState.committed;
  } catch (error, stack) {
    cause = error;
    causeStack = stack;
    if (began) {
      try {
        if (!localDatabase.autocommit) {
          localDatabase.execute('ROLLBACK;');
        } else if (commitAttempted) {
          // A failed COMMIT acknowledgement does not prove non-commit.
          state = PersistenceCommitState.unknown;
        }
      } catch (error, stack) {
        state = PersistenceCommitState.unknown;
        cleanup.add((error: error, stackTrace: stack));
      }
    }
  } finally {
    if (attached) {
      try {
        localDatabase.execute('DETACH DATABASE registration_favorites;');
      } catch (error, stack) {
        if (cause == null) {
          cause = error;
          causeStack = stack;
        } else {
          cleanup.add((error: error, stackTrace: stack));
        }
      }
    }
  }
  if (cause != null) {
    Error.throwWithStackTrace(
      PersistenceFailure(
        commitState: state,
        cause: cause,
        stackTrace: causeStack!,
        cleanupFailures: cleanup,
      ),
      causeStack,
    );
  }
}
