import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/follow_updates/follow_updates.dart';
import 'package:venera_next/foundation/log.dart';

void main() {
  const sourceKey = 'follow_updates_test_source';

  setUp(() {
    Log.isMuted = true;
  });

  tearDown(() {
    Log.isMuted = false;
    ComicSourceManager().remove(sourceKey);
  });

  test('updateComic does not wait after final retry failure', () async {
    var attempts = 0;
    final retryDelays = <Duration>[];
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

    final result = await updateComic(
      item,
      'folder',
      retryDelay: (duration) {
        retryDelays.add(duration);
        return Future.value();
      },
    );

    expect(result.updated, isFalse);
    expect(result.errorMessage, contains('network unavailable'));
    expect(attempts, 3);
    expect(retryDelays, const [Duration(seconds: 2), Duration(seconds: 2)]);
  });
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
