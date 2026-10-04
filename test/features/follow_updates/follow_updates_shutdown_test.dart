import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/follow_updates/follow_updates.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/network/request_scope.dart';

void main() {
  const sourceKey = 'follow_shutdown_source';
  const otherSourceKey = 'follow_shutdown_other_source';
  late LocalFavoritesManager? previousFavorites;
  late _Favorites favorites;

  setUp(() {
    Log.isMuted = true;
    previousFavorites = LocalFavoritesManager.cache;
    favorites = _Favorites([_item(sourceKey, 'first')]);
    LocalFavoritesManager.cache = favorites;
  });

  tearDown(() async {
    final release = await FollowUpdateJob.prepareForExit();
    release();
    LocalFavoritesManager.cache = previousFavorites;
    ComicSourceManager().remove(sourceKey);
    ComicSourceManager().remove(otherSourceKey);
    Log.isMuted = false;
  });

  test(
    'unobserved jobs are lazy and cancellation completes their done',
    () async {
      final job = FollowUpdateJob('folder', true);
      var finished = false;
      unawaited(job.done.then((_) => finished = true));
      await pumpEventQueue();
      expect(favorites.reads, 0);
      expect(finished, isFalse);

      job.cancel();
      job.cancel();
      await job.done;
      expect(await job.progress.toList(), isEmpty);
      expect(favorites.reads, 0);
      expect(favorites.writes, 0);
      expect(finished, isTrue);
    },
  );

  test(
    'preparation holds jobs and direct updates until its current release',
    () async {
      var sourceCalls = 0;
      ComicSourceManager().add(
        _source(sourceKey, (_) async {
          sourceCalls++;
          return Res(_details(sourceKey));
        }),
      );
      final unobserved = FollowUpdateJob('folder', true);
      final preparing = FollowUpdateJob.prepareForExit();
      expect(identical(preparing, FollowUpdateJob.prepareForExit()), isTrue);
      final firstRelease = await preparing;
      await unobserved.done;
      expect(unobserved.isCancelled, isTrue);
      expect(await unobserved.progress.toList(), isEmpty);

      final rejected = FollowUpdateJob('folder', true);
      await rejected.done;
      expect(await rejected.progress.toList(), isEmpty);
      expect(
        (await updateComic(favorites.comics.single, 'folder')).cancelled,
        isTrue,
      );
      expect(sourceCalls, 0);
      expect(favorites.reads, 0);

      firstRelease();
      final result = await updateComic(favorites.comics.single, 'folder');
      expect(result.updated, isTrue);
      expect(sourceCalls, 1);
      expect(favorites.writes, 2);

      final nextPreparing = FollowUpdateJob.prepareForExit();
      expect(identical(preparing, nextPreparing), isFalse);
      final nextRelease = await nextPreparing;
      firstRelease();
      expect(
        (await updateComic(favorites.comics.single, 'folder')).cancelled,
        isTrue,
      );
      expect(sourceCalls, 1);
      nextRelease();
      nextRelease();
      expect(
        (await updateComic(favorites.comics.single, 'folder')).updated,
        isTrue,
      );
      expect(sourceCalls, 2);
    },
  );

  test(
    'done and final notifications do not wait for a paused progress stream',
    () async {
      ComicSourceManager().add(
        _source(sourceKey, (_) async => Res(_details(sourceKey))),
      );
      final events = <String>[];
      favorites.onNotify = () => events.add('notified');
      final job = FollowUpdateJob('folder', true);
      final progress = <UpdateProgress>[];
      var streamEnded = false;
      final subscription = job.progress.listen(
        progress.add,
        onDone: () => streamEnded = true,
      )..pause();
      addTearDown(subscription.cancel);

      await job.done;
      events.add('done');
      final release = await FollowUpdateJob.prepareForExit();
      events.add('prepared');
      expect(events, ['notified', 'done', 'prepared']);
      expect(favorites.writes, 2);
      expect(progress, isEmpty);
      expect(streamEnded, isFalse);

      subscription.resume();
      await pumpEventQueue();
      expect(progress.last.updated, 1);
      expect(streamEnded, isTrue);
      release();
    },
  );

  test(
    'cancelling progress releases business work and isolates late source results',
    () async {
      final entered = Completer<void>();
      final response = Completer<Res<ComicDetails>>();
      late RequestScope request;
      ComicSourceManager().add(
        _source(sourceKey, (_) {
          request = RequestScope.current!;
          entered.complete();
          return response.future;
        }),
      );
      final job = FollowUpdateJob('folder', true);
      final subscription = job.progress.listen((_) {});
      await entered.future;

      await subscription.cancel();
      await job.done;
      expect(request.cancelToken.isCancelled, isTrue);
      expect(FollowUpdateJob.isChecking, isFalse);
      expect(favorites.writes, 0);
      response.complete(Res(_details(sourceKey)));
      await pumpEventQueue();
      expect(favorites.writes, 0);
      expect(favorites.notifications, 0);
    },
  );

  test(
    'preparation includes direct updates that have no job or progress subscriber',
    () async {
      final entered = Completer<void>();
      final response = Completer<Res<ComicDetails>>();
      late RequestScope request;
      ComicSourceManager().add(
        _source(sourceKey, (_) {
          request = RequestScope.current!;
          entered.complete();
          return response.future;
        }),
      );
      final updating = updateComic(favorites.comics.single, 'folder');
      await entered.future;
      final release = await FollowUpdateJob.prepareForExit();
      expect((await updating).cancelled, isTrue);
      expect(request.cancelToken.isCancelled, isTrue);
      expect(favorites.writes, 0);

      response.complete(Res(_details(sourceKey)));
      await pumpEventQueue();
      expect(favorites.writes, 0);
      release();
    },
  );

  test(
    'preparation joins a replaced job through its final notification',
    () async {
      favorites.comics = [
        _item(sourceKey, 'first'),
        _item(otherSourceKey, 'second'),
      ];
      final stalled = Completer<Res<ComicDetails>>();
      ComicSourceManager().add(
        _source(sourceKey, (_) async => Res(_details(sourceKey))),
      );
      ComicSourceManager().add(_source(otherSourceKey, (_) => stalled.future));
      final events = <String>[];
      favorites.onNotify = () => events.add('old job notified');
      final replaced = Completer<void>();
      late FollowUpdateJob next;
      late Future<void Function()> preparation;
      final old = FollowUpdateJob('folder', true);
      final subscription = old.progress.listen((progress) {
        if (progress.updated != 1 || replaced.isCompleted) return;
        favorites.comics = [];
        next = FollowUpdateJob('folder', true);
        next.progress.listen((_) {});
        preparation = FollowUpdateJob.prepareForExit();
        replaced.complete();
      });
      addTearDown(subscription.cancel);
      await replaced.future;
      final release = await preparation;
      events.add('prepared');
      await Future.wait([old.done, next.done]);
      expect(old.isCancelled, isTrue);
      expect(events, ['old job notified', 'prepared']);
      expect(favorites.writes, 2);
      expect(favorites.notifications, 1);

      stalled.complete(Res(_details(otherSourceKey)));
      await pumpEventQueue();
      expect(favorites.writes, 2);
      expect(favorites.notifications, 1);
      release();
    },
  );

  test(
    'notification failure completes done and releases a failed preparation',
    () async {
      ComicSourceManager().add(
        _source(sourceKey, (_) async => Res(_details(sourceKey))),
      );
      final failure = StateError('final favorites notification');
      late Future<void> checkedPreparation;
      favorites.onNotify = () {
        final preparation = FollowUpdateJob.prepareForExit();
        checkedPreparation = expectLater(preparation, throwsA(same(failure)));
        throw failure;
      };
      final errors = <Object>[];
      final job = FollowUpdateJob('folder', true);
      final subscription = job.progress.listen((_) {}, onError: errors.add);
      addTearDown(subscription.cancel);
      await expectLater(job.done, throwsA(same(failure)));
      await checkedPreparation;
      await pumpEventQueue();
      expect(errors, [same(failure)]);
      expect(FollowUpdateJob.isChecking, isFalse);

      favorites.onNotify = null;
      final retry = FollowUpdateJob('folder', true);
      final results = await retry.progress.toList();
      await retry.done;
      expect(results.last.updated, 1);
      expect(retry.isCancelled, isFalse);
    },
  );

  test(
    'query failure reaches progress and done without trapping later preparation',
    () async {
      final failure = StateError('favorites unavailable');
      favorites.queryFailure = failure;
      final job = FollowUpdateJob('folder', true);
      final observed = expectLater(
        job.progress.toList(),
        throwsA(same(failure)),
      );
      final completed = expectLater(job.done, throwsA(same(failure)));
      final preparation = FollowUpdateJob.prepareForExit();
      await expectLater(preparation, throwsA(same(failure)));
      await observed;
      await completed;
      favorites.queryFailure = null;
      favorites.comics = [];
      final retry = FollowUpdateJob('folder', true);
      expect((await retry.progress.toList()).single.fraction, 1);
      await retry.done;
      final release = await FollowUpdateJob.prepareForExit();
      release();
    },
  );
}

FavoriteItemWithUpdateInfo _item(String key, String id) =>
    FavoriteItemWithUpdateInfo(
      FavoriteItem(
        id: id,
        name: id,
        coverPath: '',
        author: '',
        type: ComicType.fromKey(key),
        tags: [],
      ),
      null,
      false,
      null,
    );

ComicDetails _details(String key) => ComicDetails.fromJson({
  'title': 'Updated title',
  'cover': '',
  'tags': <String, dynamic>{},
  'sourceKey': key,
  'comicId': 'first',
  'updateTime': '2026-10-04',
});

class _Favorites extends Fake implements LocalFavoritesManager {
  _Favorites(this.comics);
  List<FavoriteItemWithUpdateInfo> comics;
  Object? queryFailure;
  void Function()? onNotify;
  int reads = 0;
  int writes = 0;
  int notifications = 0;
  @override
  List<FavoriteItemWithUpdateInfo> getComicsWithUpdatesInfo(String folder) {
    reads++;
    final failure = queryFailure;
    if (failure != null) throw failure;
    return comics;
  }

  @override
  void updateInfo(String folder, FavoriteItem comic, [bool notify = true]) =>
      writes++;
  @override
  void updateCheckTime(String folder, String id, ComicType type) => writes++;
  @override
  void updateUpdateTime(
    String folder,
    String id,
    ComicType type,
    String updateTime,
  ) => writes++;
  @override
  void notifyChanges() {
    notifications++;
    onNotify?.call();
  }
}

ComicSource _source(String key, LoadComicFunc loadComicInfo) => ComicSource(
  'Shutdown Source',
  key,
  null,
  null,
  null,
  null,
  const [],
  null,
  null,
  loadComicInfo,
  null,
  null,
  null,
  null,
  'test.js',
  '',
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
