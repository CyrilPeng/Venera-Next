import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/history/history_manager.dart';
import 'package:venera_next/features/history/image_favorite_actions.dart';
import 'package:venera_next/features/history/image_favorites.dart';
import 'package:venera_next/features/history/image_favorites_models.dart';
import 'package:venera_next/features/history/image_favorites_statistics.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/persistence_failure.dart';
import 'image_favorites_repository_test.dart' show comic;
import '../reader/image_favorite_actions_test.dart' show selection;

void main() {
  late Directory root;
  late HistoryManager history;
  late ImageFavoriteManager manager;
  late AppDataOperations operations;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('image-admission-');
    App.dataPath = root.path;
    App.cachePath = root.path;
    operations = AppDataOperations();
    history = HistoryManager.create(operations: operations);
    manager = ImageFavoriteManager.create(history: history);
    await history.init();
  });

  tearDown(() async {
    await history.waitForAsyncWrites();
    manager.dispose();
    history.close();
    root.deleteSync(recursive: true);
  });

  Future<void> seed(Iterable<ImageFavoritesComic> comics) => history
      .accessImageFavorites((repository, _) => repository.saveAll(comics));

  test('queued toggle uses imported content and detached intent', () async {
    final closed = Completer<void>();
    final release = Completer<void>();
    final replacing = operations.run(() async {
      history.close();
      closed.complete();
      await release.future;
      final target = Directory('${root.path}/replacement')..createSync();
      App.dataPath = target.path;
      await history.init();
      await seed([comic('comic')]);
    });
    await closed.future;
    final input = selection(page: 3);
    final editing = manager.toggle(input);
    input.tags.clear();
    input.translatedTags.clear();
    final reading = manager.getAll();
    release.complete();
    await replacing;
    expect(await editing, ImageFavoriteResult.collected);
    final stored = (await reading).single;
    expect(stored.title, 'Title comic');
    expect(stored.images.map((image) => image.page), [1, 3]);
    expect(stored.tags, ['Tag', '', 'more']);
    final old = sqlite3.open('${root.path}/history.db');
    try {
      expect(old.select('SELECT * FROM image_favorites'), isEmpty);
    } finally {
      old.dispose();
    }
  });

  test(
    'queued creation snapshots caller lists and concurrent toggles compose',
    () async {
      final release = Completer<void>();
      final blocked = operations.run(() => release.future);
      final input = selection();
      final first = manager.toggle(input);
      input.tags.clear();
      input.translatedTags.clear();
      final second = manager.toggle(selection(page: 3));
      release.complete();
      await Future.wait([blocked, first, second]);
      final stored = (await manager.find('comic', 'source'))!;
      expect(stored.images.map((image) => image.page), [1, 2, 3]);
      expect(stored.tags, ['tag']);
      expect(stored.translatedTags, ['translated']);
      expect(
        await manager.toggle(selection(page: 1)),
        ImageFavoriteResult.protectedCover,
      );
      expect(
        await manager.toggle(selection()),
        ImageFavoriteResult.uncollected,
      );
      expect(
        await manager.isCollected('comic', 'source', 'chapter', 2),
        isFalse,
      );
    },
  );

  test('cancelled queued selection never starts SQL or notification', () async {
    final release = Completer<void>();
    final blocked = operations.run(() => release.future);
    var notifications = 0;
    manager.addListener(() => notifications++);
    final editing = manager.toggle(
      selection(),
      checkActive: () => throw StateError('cancelled'),
    );
    final observed = expectLater(editing, throwsStateError);
    release.complete();
    await blocked;
    await observed;
    expect(await manager.getAll(), isEmpty);
    expect(notifications, 0);
  });

  test(
    'deletion captures mutable selection and preserves other pages',
    () async {
      await manager.toggle(selection());
      await manager.toggle(selection(page: 3));
      final selected = (await manager.find(
        'comic',
        'source',
      ))!.images.where((image) => image.page == 2).toList();
      final release = Completer<void>();
      final blocked = operations.run(() => release.future);
      final deleting = manager.deleteImageFavorite(selected);
      selected.single.page = 3;
      selected.clear();
      release.complete();
      await Future.wait([blocked, deleting]);
      expect(
        (await manager.find(
          'comic',
          'source',
        ))!.images.map((image) => image.page),
        [1, 3],
      );
    },
  );

  test(
    'storage rejection leaves data and notification untouched and allows retry',
    () async {
      var notifications = 0;
      manager.addListener(() => notifications++);
      history.imageFavoritesDatabase.execute(
        "CREATE TRIGGER reject_favorite BEFORE INSERT ON image_favorites BEGIN SELECT RAISE(ABORT, 'rejected'); END;",
      );
      await expectLater(
        manager.toggle(selection()),
        throwsA(isA<SqliteException>()),
      );
      expect(await manager.getAll(), isEmpty);
      expect(notifications, 0);
      history.imageFavoritesDatabase.execute('DROP TRIGGER reject_favorite');
      expect(await manager.toggle(selection()), ImageFavoriteResult.collected);
      expect(notifications, 1);
    },
  );

  test(
    'committed deletion waits for every cache cleanup and reports all failures',
    () async {
      await seed([comic('first'), comic('second')]);
      final release = Completer<void>();
      final started = <String>[];
      final errors = [StateError('first cache'), StateError('second cache')];
      manager.dispose();
      manager = ImageFavoriteManager.create(
        history: history,
        deleteCache: (image) async {
          started.add(image.id);
          await release.future;
          throw image.id == 'first' ? errors[0] : errors[1];
        },
      );
      var notifications = 0;
      manager.addListener(() => notifications++);
      final deleting = manager.deleteImageFavorite([
        comic('first').images.single,
        comic('second').images.single,
      ]);
      final observed = expectLater(
        deleting,
        throwsA(
          isA<PersistenceFailure>()
              .having(
                (error) => error.commitState,
                'commit',
                PersistenceCommitState.committed,
              )
              .having(
                (error) => {
                  error.cause,
                  ...error.cleanupFailures.map((failure) => failure.error),
                },
                'causes',
                errors.toSet(),
              ),
        ),
      );
      var replaced = false;
      final replacing = operations.run(() => replaced = true);
      await Future<void>.delayed(Duration.zero);
      expect(started, ['first', 'second']);
      expect(notifications, 0);
      expect(replaced, isFalse);
      release.complete();
      await observed;
      await replacing;
      expect(notifications, 1);
      expect(await manager.getAll(), isEmpty);
    },
  );

  test(
    'notification-triggered replacement cannot borrow mutation ownership',
    () async {
      final events = <String>[];
      Future<void>? replacing;
      void listener() {
        manager.removeListener(listener);
        replacing = operations.run(() async {
          await history.waitForAsyncWrites();
          events.add('replace');
        });
        events.add('notified');
      }

      manager.addListener(listener);
      await manager.toggle(selection());
      await replacing;
      expect(events, ['notified', 'replace']);
    },
  );

  test(
    'statistics threshold retains ranking and uses a real read-only worker',
    () async {
      final input = List.generate(101, (index) => comic('book-$index'));
      await seed(input.take(100));
      var workers = 0;
      manager.dispose();
      manager = ImageFavoriteManager.create(
        history: history,
        readStatistics: (path) {
          workers++;
          return readImageFavoritesStatistics(path);
        },
      );
      expect((await manager.compute()).count, 100);
      expect(workers, 0);
      await seed([input.last]);
      final computed = await manager.compute();
      expect(workers, 1);
      expect(computed.count, 101);
      expect(computed.tags.map((tag) => (tag.text, tag.count)), [
        ('Tag', 101),
        ('more', 101),
      ]);
      expect(computed.authors.map((author) => (author.text, author.count)), [
        ('Author', 101),
      ]);
      expect(computed.comics, hasLength(20));
      // A leaked worker connection would prevent Windows file replacement.
      await operations.run(() async {
        history.close();
        final file = File('${root.path}/history.db');
        file.renameSync('${root.path}/old.db');
        await history.init();
      });
      expect((await manager.compute()).count, 0);
    },
  );

  test(
    'replacement and shutdown drain an accepted statistics worker',
    () async {
      await seed(List.generate(101, (index) => comic('book-$index')));
      final started = Completer<void>();
      final release = Completer<void>();
      manager.dispose();
      manager = ImageFavoriteManager.create(
        history: history,
        readStatistics: (path) async {
          started.complete();
          await release.future;
          return readImageFavoritesStatistics(path);
        },
      );
      final computing = manager.compute();
      await started.future;
      var drained = false;
      final draining = history.waitForAsyncWrites().then((_) => drained = true);
      var replaced = false;
      final replacing = operations.run(() => replaced = true);
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      expect(replaced, isFalse);
      release.complete();
      expect((await computing).count, 101);
      await Future.wait([draining, replacing]);
      expect(drained, isTrue);
      expect(replaced, isTrue);
    },
  );

  test('read-only statistics failures neither create nor alter data', () async {
    final absent = '${root.path}/absent.db';
    await expectLater(
      readImageFavoritesStatistics(absent),
      throwsA(isA<SqliteException>()),
    );
    expect(File(absent).existsSync(), isFalse);
    await seed([comic('broken')]);
    history.imageFavoritesDatabase.execute(
      "UPDATE image_favorites SET image_favorites_ep = 'invalid-json'",
    );
    await expectLater(
      readImageFavoritesStatistics('${root.path}/history.db'),
      throwsFormatException,
    );
    expect(
      history.imageFavoritesDatabase
          .select('SELECT image_favorites_ep FROM image_favorites')
          .single['image_favorites_ep'],
      'invalid-json',
    );
  });
}
