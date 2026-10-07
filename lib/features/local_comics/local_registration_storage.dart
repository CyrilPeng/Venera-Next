import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/favorites/favorites_api.dart';
import 'package:venera_next/features/favorites/favorites_repository.dart';
import 'package:venera_next/foundation/persistence_failure.dart';

import 'local_comic_model.dart';
import 'local_repository.dart';

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
    local.add(comic, id);
    final added = FavoritesRepository(localDatabase).addComic(
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
