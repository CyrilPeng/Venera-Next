import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/follow_updates/follow_updates.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/network/request_scope.dart';

void main() {
  const sourceKey = 'follow_updates_test_source';

  setUp(() {
    Log.isMuted = true;
  });

  tearDown(() {
    Log.isMuted = false;
    ComicSourceManager().remove(sourceKey);
  });

  test(
    'updateComic does not retry errors already handled by the source',
    () async {
      var attempts = 0;
      final source = _source(
        sourceKey,
        loadComicInfo: (id) async {
          attempts++;
          throw 'network unavailable';
        },
      );
      ComicSourceManager().add(source);

      final item = FavoriteItemWithUpdateInfo(
        FavoriteItem(
          id: 'comic-1',
          name: 'Comic 1',
          coverPath: 'cover.jpg',
          author: 'Author',
          type: ComicType.fromKey(sourceKey),
          tags: const [],
        ),
        null,
        false,
        null,
      );

      final result = await updateComic(item, 'folder');

      expect(result.updated, isFalse);
      expect(result.errorMessage, contains('network unavailable'));
      expect(attempts, 1);
    },
  );

  test(
    'cancelling a job stops queued checks and prevents late writes',
    () async {
      final previous = LocalFavoritesManager.cache;
      final favorites = _Favorites(
        List.generate(12, (i) => _item(sourceKey, '$i')),
      );
      LocalFavoritesManager.cache = favorites;
      final replies = <Completer<Res<ComicDetails>>>[];
      final tokens = <RequestScope>[];
      ComicSourceManager().add(
        _source(
          sourceKey,
          loadComicInfo: (_) {
            tokens.add(RequestScope.current!);
            final reply = Completer<Res<ComicDetails>>();
            replies.add(reply);
            return reply.future;
          },
        ),
      );
      try {
        final job = FollowUpdateJob('folder', true);
        final finished = job.progress.toList();
        await pumpEventQueue();
        expect(replies, hasLength(1));
        job.cancel();
        await finished;
        expect(tokens.single.cancelToken.isCancelled, isTrue);
        replies.single.complete(Res(_details(sourceKey)));
        await pumpEventQueue();
        expect(replies, hasLength(1));
        expect(favorites.writes, 0);
      } finally {
        LocalFavoritesManager.cache = previous;
      }
    },
  );

  test(
    'new checks replace old checks and empty jobs complete normally',
    () async {
      final previous = LocalFavoritesManager.cache;
      final favorites = _Favorites([_item(sourceKey, '1')]);
      LocalFavoritesManager.cache = favorites;
      ComicSourceManager().add(
        _source(
          sourceKey,
          loadComicInfo: (_) => Completer<Res<ComicDetails>>().future,
        ),
      );
      try {
        final first = FollowUpdateJob('folder', true);
        final old = first.progress.toList();
        await pumpEventQueue();
        favorites.comics = [];
        final next = FollowUpdateJob('folder', true);
        final progress = await next.progress.toList();
        await old;
        expect(first.isCancelled, isTrue);
        expect(next.isCancelled, isFalse);
        expect(progress.single.fraction, 1);
        expect(FollowUpdateJob.isChecking, isFalse);
      } finally {
        LocalFavoritesManager.cache = previous;
      }
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
  'title': 'New title',
  'cover': '',
  'tags': <String, dynamic>{},
  'sourceKey': key,
  'comicId': '1',
});

class _Favorites extends Fake implements LocalFavoritesManager {
  _Favorites(this.comics);
  List<FavoriteItemWithUpdateInfo> comics;
  int writes = 0;
  @override
  List<FavoriteItemWithUpdateInfo> getComicsWithUpdatesInfo(String folder) =>
      comics;
  @override
  void updateInfo(String folder, FavoriteItem comic, [bool notify = true]) =>
      writes++;
  @override
  void updateCheckTime(String folder, String id, ComicType type) => writes++;
}

ComicSource _source(String key, {LoadComicFunc? loadComicInfo}) {
  return ComicSource(
    'Test Source',
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
}
