import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/history/history_manager.dart';
import 'package:venera_next/features/history/history_model.dart';
import 'package:venera_next/features/history/history_repository.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/persistence_failure.dart';

History _history(String id) => History.fromMap({
  'type': ComicType.local.value,
  'time': DateTime(2026, 10, 4).millisecondsSinceEpoch,
  'title': 'Title $id',
  'subtitle': 'Author',
  'cover': 'cover.jpg',
  'ep': 1,
  'page': 2,
  'id': id,
  'readEpisode': ['1'],
  'max_page': 10,
});

class _ThrowingHistoryManager extends HistoryManager {
  _ThrowingHistoryManager({super.writeDuration}) : super.create();

  final notificationFailure = StateError('history notification failed');
  bool failNotifications = false;
  int notificationCalls = 0;

  @override
  void notifyListeners() {
    notificationCalls++;
    if (failNotifications) throw notificationFailure;
    super.notifyListeners();
  }
}

class _UnprintableFailure implements Exception {
  int stringifications = 0;

  @override
  String toString() {
    stringifications++;
    throw StateError('error formatting failed');
  }
}

Future<void> _persistDuration(
  String path,
  History snapshot,
  int durationMs,
) async {
  final database = sqlite3.open(path);
  try {
    HistoryRepository(database).addReadDuration(snapshot, durationMs);
  } finally {
    database.dispose();
  }
}

bool _sqliteAvailable() {
  try {
    final database = sqlite3.openInMemory();
    database.dispose();
    return true;
  } catch (_) {
    return false;
  }
}

Matcher _uncommittedSqliteFailure() => isA<PersistenceFailure>()
    .having(
      (failure) => failure.commitState,
      'commit state',
      PersistenceCommitState.notCommitted,
    )
    .having((failure) => failure.cause, 'cause', isA<SqliteException>());

void main() {
  group(
    'reading duration commit evidence',
    () {
      late Directory directory;
      late _ThrowingHistoryManager manager;
      late Database database;

      setUp(() async {
        directory = Directory.systemTemp.createTempSync('history-commit-');
        App.dataPath = directory.path;
        App.cachePath = directory.path;
        manager = _ThrowingHistoryManager();
        await manager.init();
        database = sqlite3.open('${directory.path}/history.db');
      });

      tearDown(() async {
        manager.failNotifications = false;
        await manager.waitForAsyncWrites();
        database.dispose();
        manager.close();
        directory.deleteSync(recursive: true);
      });

      int? storedDuration(String id) {
        final rows = database.select(
          'SELECT read_duration_ms FROM history WHERE id = ? AND type = ?',
          [id, ComicType.local.value],
        );
        return rows.isEmpty ? null : rows.single['read_duration_ms'] as int;
      }

      Future<void> replaceDurationWriter(
        HistoryDurationStorageWriter writer,
      ) async {
        manager.close();
        manager = _ThrowingHistoryManager(writeDuration: writer);
        await manager.init();
      }

      test(
        'aborted update can be retried once and later writes continue',
        () async {
          final item = _history('existing');
          await manager.addReadDuration(item, const Duration(milliseconds: 30));
          database.execute('''
        CREATE TRIGGER reject_duration_update BEFORE UPDATE ON history
        WHEN NEW.id = 'existing'
        BEGIN SELECT RAISE(ABORT, 'duration update rejected'); END;
      ''');

          final rejected = expectLater(
            manager.addReadDuration(item, const Duration(milliseconds: 90)),
            throwsA(_uncommittedSqliteFailure()),
          );
          final following = manager.addReadDuration(
            _history('following'),
            const Duration(milliseconds: 20),
          );
          await rejected;
          await following;
          expect(storedDuration('existing'), 30);
          expect(item.readDurationMs, 30);
          expect(storedDuration('following'), 20);

          database.execute('DROP TRIGGER reject_duration_update');
          await manager.addReadDuration(item, const Duration(milliseconds: 90));
          await manager.waitForAsyncWrites();
          expect(storedDuration('existing'), 120);
          expect(item.readDurationMs, 120);
          expect(manager.find(item.id, item.type)!.readDurationMs, 120);
          expect(manager.hasPendingWrites, isFalse);
        },
      );

      test(
        'aborted insert leaves no row and retry only adds one period',
        () async {
          final item = _history('new');
          database.execute('''
        CREATE TRIGGER reject_duration_insert BEFORE INSERT ON history
        WHEN NEW.id = 'new'
        BEGIN SELECT RAISE(ABORT, 'duration insert rejected'); END;
      ''');

          final rejected = expectLater(
            manager.addReadDuration(item, const Duration(milliseconds: 80)),
            throwsA(_uncommittedSqliteFailure()),
          );
          final following = manager.addHistory(_history('following'));
          await rejected;
          await following;
          expect(storedDuration('new'), isNull);
          expect(item.readDurationMs, 0);
          expect(manager.find('following', ComicType.local), isNotNull);

          database.execute('DROP TRIGGER reject_duration_insert');
          await manager.addReadDuration(item, const Duration(milliseconds: 80));
          await manager.waitForAsyncWrites();
          expect(storedDuration('new'), 80);
          expect(item.readDurationMs, 80);
          expect(manager.find(item.id, item.type)!.readDurationMs, 80);
          expect(manager.hasPendingWrites, isFalse);
        },
      );

      test(
        'failed notification reports committed and does not replay the period',
        () async {
          final item = _history('notified');
          await manager.addReadDuration(item, const Duration(milliseconds: 30));
          manager.failNotifications = true;

          await expectLater(
            manager.addReadDuration(item, const Duration(milliseconds: 80)),
            throwsA(
              isA<PersistenceFailure>()
                  .having(
                    (failure) => failure.commitState,
                    'commit state',
                    PersistenceCommitState.committed,
                  )
                  .having(
                    (failure) => failure.cause,
                    'cause',
                    same(manager.notificationFailure),
                  ),
            ),
          );
          expect(storedDuration('notified'), 110);
          expect(item.readDurationMs, 110);
          expect(manager.find(item.id, item.type)!.readDurationMs, 110);

          manager.failNotifications = false;
          await manager.addHistory(item.copy()..page = 7);
          await manager.addReadDuration(item, const Duration(milliseconds: 20));
          await manager.waitForAsyncWrites();
          expect(storedDuration('notified'), 130);
          expect(manager.find(item.id, item.type)!.page, 7);
          expect(manager.hasPendingWrites, isFalse);
        },
      );

      test('committed cleanup failure still publishes exactly once', () async {
        final cleanupError = StateError('connection cleanup failed');
        final cleanupStack = StackTrace.current;
        final failure = PersistenceFailure(
          commitState: PersistenceCommitState.committed,
          cause: cleanupError,
          stackTrace: cleanupStack,
        );
        var storageCalls = 0;
        await replaceDurationWriter((path, snapshot, durationMs) async {
          storageCalls++;
          await _persistDuration(path, snapshot, durationMs);
          Error.throwWithStackTrace(failure, cleanupStack);
        });
        final item = _history('cleanup');
        await manager.addHistory(item);
        final cachedBefore = manager.find(item.id, item.type)!;
        expect(cachedBefore.readDurationMs, 0);
        manager.notificationCalls = 0;
        var listenerCalls = 0;
        manager.addListener(() => listenerCalls++);

        await expectLater(
          manager.addReadDuration(item, const Duration(milliseconds: 80)),
          throwsA(same(failure)),
        );
        await manager.waitForAsyncWrites();
        expect(storedDuration(item.id), 80);
        expect(item.readDurationMs, 80);
        expect(manager.find(item.id, item.type)!.readDurationMs, 80);
        expect(manager.notificationCalls, 1);
        expect(listenerCalls, 1);
        expect(storageCalls, 1);
        expect(manager.hasPendingWrites, isFalse);
      });

      test(
        'publication failure preserves the committed cleanup primary cause',
        () async {
          final cleanupError = StateError('connection cleanup failed');
          final cleanupStack = StackTrace.current;
          final earlierCleanupError = StateError('other cleanup failed');
          final earlierCleanupStack = StackTrace.current;
          final failure = PersistenceFailure(
            commitState: PersistenceCommitState.committed,
            cause: cleanupError,
            stackTrace: cleanupStack,
            cleanupFailures: [
              (error: earlierCleanupError, stackTrace: earlierCleanupStack),
            ],
          );
          await replaceDurationWriter((path, snapshot, durationMs) async {
            await _persistDuration(path, snapshot, durationMs);
            Error.throwWithStackTrace(failure, cleanupStack);
          });
          final item = _history('cleanup-and-notification');
          await manager.addHistory(item);
          expect(manager.find(item.id, item.type)!.readDurationMs, 0);
          manager.notificationCalls = 0;
          manager.failNotifications = true;

          await expectLater(
            manager.addReadDuration(item, const Duration(milliseconds: 90)),
            throwsA(
              isA<PersistenceFailure>()
                  .having(
                    (failure) => failure.commitState,
                    'already committed',
                    PersistenceCommitState.committed,
                  )
                  .having(
                    (failure) => failure.cause,
                    'primary cause',
                    same(cleanupError),
                  )
                  .having(
                    (failure) => failure.stackTrace,
                    'primary stack',
                    same(cleanupStack),
                  )
                  .having(
                    (failure) =>
                        failure.cleanupFailures.map((entry) => entry.error),
                    'all cleanup and publication causes',
                    [
                      same(earlierCleanupError),
                      same(manager.notificationFailure),
                    ],
                  )
                  .having(
                    (failure) => failure.cleanupFailures.first.stackTrace,
                    'earlier cleanup stack',
                    same(earlierCleanupStack),
                  )
                  .having(
                    (failure) =>
                        failure.cleanupFailures.last.stackTrace.toString(),
                    'publication stack',
                    contains('_ThrowingHistoryManager.notifyListeners'),
                  ),
            ),
          );
          expect(storedDuration(item.id), 90);
          expect(item.readDurationMs, 90);
          expect(manager.find(item.id, item.type)!.readDurationMs, 90);
          expect(manager.notificationCalls, 1);
          expect(manager.hasPendingWrites, isFalse);
        },
      );

      test(
        'unclassified writer failure is unknown even if storage committed',
        () async {
          final writerError = StateError('worker result was lost');
          final writerStack = StackTrace.current;
          var storageCalls = 0;
          await replaceDurationWriter((path, snapshot, durationMs) async {
            storageCalls++;
            await _persistDuration(path, snapshot, durationMs);
            if (storageCalls == 1) {
              Error.throwWithStackTrace(writerError, writerStack);
            }
          });
          final item = _history('unknown');
          manager.notificationCalls = 0;

          await expectLater(
            manager.addReadDuration(item, const Duration(milliseconds: 60)),
            throwsA(
              isA<PersistenceFailure>()
                  .having(
                    (failure) => failure.commitState,
                    'unknown commit outcome',
                    PersistenceCommitState.unknown,
                  )
                  .having(
                    (failure) => failure.cause,
                    'original cause',
                    same(writerError),
                  )
                  .having(
                    (failure) => failure.stackTrace,
                    'original stack',
                    same(writerStack),
                  ),
            ),
          );
          expect(storedDuration(item.id), 60);
          expect(item.readDurationMs, 0);
          expect(manager.notificationCalls, 0);
          final following = _history('after-unknown');
          await manager.addReadDuration(
            following,
            const Duration(milliseconds: 20),
          );
          await manager.waitForAsyncWrites();
          expect(storageCalls, 2);
          expect(storedDuration(item.id), 60);
          expect(storedDuration(following.id), 20);
          expect(following.readDurationMs, 20);
          expect(manager.notificationCalls, 1);
          expect(manager.hasPendingWrites, isFalse);
        },
      );

      test(
        'a logging failure cannot poison later accepted duration writes',
        () async {
          final error = _UnprintableFailure();
          final failedImport = manager.importStorage(
            (_) => throw error,
            onCommitted: () => fail('failed import must not publish'),
          );
          final observed = expectLater(failedImport, throwsA(same(error)));
          final item = _history('after-logging-failure');
          final following = manager.addReadDuration(
            item,
            const Duration(milliseconds: 70),
          );
          await observed;
          await following;
          await manager.waitForAsyncWrites();
          expect(error.stringifications, greaterThan(0));
          expect(storedDuration(item.id), 70);
          expect(item.readDurationMs, 70);
          expect(manager.find(item.id, item.type)!.readDurationMs, 70);
          expect(manager.hasPendingWrites, isFalse);
        },
      );

      test(
        'duration rejected after close is definitively uncommitted',
        () async {
          var storageCalls = 0;
          await replaceDurationWriter((path, snapshot, durationMs) async {
            storageCalls++;
            await _persistDuration(path, snapshot, durationMs);
          });
          final item = _history('closed');
          manager.close();
          await expectLater(
            manager.addReadDuration(item, const Duration(milliseconds: 50)),
            throwsA(
              isA<PersistenceFailure>()
                  .having(
                    (failure) => failure.commitState,
                    'rejected before storage',
                    PersistenceCommitState.notCommitted,
                  )
                  .having(
                    (failure) => failure.cause,
                    'closed database',
                    isA<StateError>(),
                  ),
            ),
          );
          expect(storageCalls, 0);
          expect(item.readDurationMs, 0);
          expect(storedDuration(item.id), isNull);
          expect(manager.hasPendingWrites, isFalse);
        },
      );

      test(
        'durations accepted before close finish on their original database',
        () async {
          final started = Completer<void>();
          final release = Completer<void>();
          final paths = <String>[];
          await replaceDurationWriter((path, snapshot, durationMs) async {
            paths.add(path);
            if (paths.length == 1) {
              started.complete();
              await release.future;
            }
            await _persistDuration(path, snapshot, durationMs);
          });
          final originalPath = '${directory.path}/history.db';
          final firstItem = _history('accepted-first');
          final secondItem = _history('accepted-second');
          final first = manager.addReadDuration(
            firstItem,
            const Duration(milliseconds: 30),
          );
          final second = manager.addReadDuration(
            secondItem,
            const Duration(milliseconds: 40),
          );
          await started.future;
          manager.close();
          final reopenedDirectory = Directory('${directory.path}/reopened')
            ..createSync();
          App.dataPath = reopenedDirectory.path;
          final reopened = manager.init();
          manager.notificationCalls = 0;
          release.complete();
          await Future.wait([first, second, reopened]);
          expect(paths, [originalPath, originalPath]);
          expect(storedDuration(firstItem.id), 30);
          expect(storedDuration(secondItem.id), 40);
          expect(firstItem.readDurationMs, 30);
          expect(secondItem.readDurationMs, 40);
          expect(manager.find(firstItem.id, firstItem.type), isNull);
          expect(manager.find(secondItem.id, secondItem.type), isNull);
          expect(manager.length, 0);
          expect(manager.notificationCalls, 1);
          expect(manager.hasPendingWrites, isFalse);
        },
      );
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );
}
