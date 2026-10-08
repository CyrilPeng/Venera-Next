import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/history/history_api.dart';
import 'package:venera_next/features/local_comics/local_comics_api.dart';
import 'package:venera_next/features/reader/reader_entry_loader.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/network/request_scope.dart';

ComicDetails details(
  String id, {
  String source = 'source',
  bool author = true,
}) => ComicDetails.fromJson({
  'title': 'Online $id',
  'cover': 'cover.jpg',
  'sourceKey': source,
  'comicId': id,
  'tags': {
    if (author) 'artist': ['Artist'],
    'genre': ['Adventure', 'Comedy'],
  },
  'chapters': {'chapter-b': 'Second', 'chapter-a': 'First'},
});

LocalComic localComic(String id, ComicType type) => LocalComic(
  id: id,
  title: 'Local $id',
  subtitle: 'Local author',
  tags: const ['local tag'],
  directory: 'book',
  chapters: ComicChapters.fromJsonOrNull({'eid-b': 'B', 'eid-a': 'A'}),
  cover: 'cover.jpg',
  comicType: type,
  downloadedChapters: const ['eid-b', 'eid-a'],
  createdAt: DateTime(2020),
);

void main() {
  RequestScope scope() {
    final value = RequestScope();
    addTearDown(value.dispose);
    return value;
  }

  test(
    'absent source uses local metadata and preserves existing history',
    () async {
      final type = ComicType.fromKey('removed-source');
      final local = localComic('book', type);
      final history = History.fromModel(
        model: local,
        ep: 7,
        page: 12,
        group: 2,
      );
      final calls = <String>[];
      final loader = ReaderEntryLoader(
        resolveComicLoader: (key) {
          calls.add('source:$key');
          return null;
        },
        findHistory: (id, actualType) {
          expect(actualType, type);
          calls.add('history:$id');
          return history;
        },
        findLocalComic: (id, actualType) {
          expect(actualType, type);
          calls.add('local:$id');
          return local;
        },
      );
      final result = await loader.load(
        id: 'book',
        sourceKey: 'removed-source',
        scope: scope(),
      );
      expect(calls, ['source:removed-source', 'history:book', 'local:book']);
      expect(result.data.name, 'Local book');
      expect(result.data.type, type);
      expect(result.data.chapters, same(local.chapters));
      expect(result.data.author, 'Local author');
      expect(result.data.tags, ['local tag']);
      expect(result.data.history, same(history));
      expect((history.ep, history.page, history.group), (7, 12, 2));
    },
  );

  test(
    'new local history retains zero initial position and local type',
    () async {
      final local = localComic('local-id', ComicType.local);
      final loader = ReaderEntryLoader(
        resolveComicLoader: (_) => null,
        findHistory: (_, _) => null,
        findLocalComic: (_, type) {
          expect(type, ComicType.local);
          return local;
        },
      );
      final result = await loader.load(
        id: 'local-id',
        sourceKey: 'local',
        scope: scope(),
      );
      expect(result.data.history.type, ComicType.local);
      expect(result.data.history.id, 'local-id');
      expect((result.data.history.ep, result.data.history.page), (0, 0));
      expect(result.data.history.readEpisode, isEmpty);
    },
  );

  test(
    'missing source and local record retain the existing error message',
    () async {
      final loader = ReaderEntryLoader(
        resolveComicLoader: (_) => null,
        findHistory: (_, _) => null,
        findLocalComic: (_, _) => null,
      );
      final result = await loader.load(
        id: 'missing',
        sourceKey: 'local',
        scope: scope(),
      );
      expect(result.errorMessage, 'comic not found');
    },
  );

  test(
    'installed source supplies metadata without querying the local catalog',
    () async {
      final comic = details('online-id');
      final history = History.fromModel(model: comic, ep: 3, page: 8, group: 1);
      final loader = ReaderEntryLoader(
        resolveComicLoader: (key) {
          expect(key, 'source');
          return (id) async {
            expect(id, 'online-id');
            return Res(comic);
          };
        },
        findHistory: (_, _) => history,
        findLocalComic: (_, _) => throw StateError('Unexpected local fallback'),
      );
      final result = await loader.load(
        id: 'online-id',
        sourceKey: 'source',
        scope: scope(),
      );
      expect(result.data.type, ComicType.fromKey('source'));
      expect(result.data.cid, 'online-id');
      expect(result.data.chapters, same(comic.chapters));
      expect(result.data.author, 'Artist');
      expect(result.data.tags, [
        'artist:Artist',
        'genre:Adventure',
        'genre:Comedy',
      ]);
      expect(result.data.history, same(history));
      expect((history.ep, history.page, history.group), (3, 8, 1));
    },
  );

  test(
    'new online history and missing author preserve existing defaults',
    () async {
      final loader = ReaderEntryLoader(
        resolveComicLoader: (_) =>
            (id) async => Res(details(id, author: false)),
        findHistory: (_, _) => null,
        findLocalComic: (_, _) => throw StateError('Unexpected local fallback'),
      );
      final result = await loader.load(
        id: 'book',
        sourceKey: 'source',
        scope: scope(),
      );
      expect(result.data.author, '');
      expect(result.data.history.id, 'book');
      expect(result.data.history.title, 'Online book');
      expect((result.data.history.ep, result.data.history.page), (0, 0));
      expect(result.data.history.type, ComicType.fromKey('source'));
    },
  );

  test(
    'source result failure and thrown error do not fall back or lose cause',
    () async {
      final cause = UnsupportedError('details unavailable');
      final stack = StackTrace.fromString('original source stack');
      var throwsError = false;
      final failure = Res<ComicDetails>.fromException(cause, stack);
      final loader = ReaderEntryLoader(
        resolveComicLoader: (_) => (_) async {
          if (throwsError) Error.throwWithStackTrace(cause, stack);
          return failure;
        },
        findHistory: (_, _) => null,
        findLocalComic: (_, _) => throw StateError('Unexpected local fallback'),
      );
      final result = await loader.load(
        id: 'book',
        sourceKey: 'source',
        scope: scope(),
      );
      expect(result.failure, same(failure.failure));
      expect(result.errorMessage, failure.errorMessage);
      throwsError = true;
      try {
        await loader.load(id: 'book', sourceKey: 'source', scope: scope());
        fail('Expected original error');
      } catch (error, actualStack) {
        expect(error, same(cause));
        expect(actualStack.toString(), contains('original source stack'));
      }
    },
  );

  test(
    'cancellation waits for the original source and rejects its late result',
    () async {
      final original = Completer<Res<ComicDetails>>();
      final owner = scope();
      var settled = false;
      final loader = ReaderEntryLoader(
        resolveComicLoader: (_) =>
            (_) => original.future,
        findHistory: (_, _) => null,
        findLocalComic: (_, _) => throw StateError('Unexpected local fallback'),
      );
      final expectation = expectLater(
        loader.load(id: 'book', sourceKey: 'source', scope: owner),
        throwsA(isA<RequestCancelled>()),
      ).then((_) => settled = true);
      owner.cancel();
      await pumpEventQueue();
      expect(settled, isFalse);
      original.complete(Res(details('book')));
      await expectation;
    },
  );

  test(
    'cancelled admission performs no queries and independent loaders stay isolated',
    () async {
      final calls = <String>[];
      ReaderEntryLoader loader(String source) => ReaderEntryLoader(
        resolveComicLoader: (_) {
          calls.add(source);
          return (id) async => Res(details(id, source: source));
        },
        findHistory: (_, _) => null,
        findLocalComic: (_, _) => throw StateError('Unexpected local fallback'),
      );
      final first = loader('first');
      final second = loader('second');
      final cancelled = scope()..cancel();
      await expectLater(
        first.load(id: 'rejected', sourceKey: 'first', scope: cancelled),
        throwsA(isA<RequestCancelled>()),
      );
      expect(calls, isEmpty);
      final results = await Future.wait([
        first.load(id: 'one', sourceKey: 'first', scope: scope()),
        second.load(id: 'two', sourceKey: 'second', scope: scope()),
      ]);
      expect(calls, ['first', 'second']);
      expect(results[0].data.history.type, ComicType.fromKey('first'));
      expect(results[1].data.history.type, ComicType.fromKey('second'));
      expect(results.map((r) => r.data.cid), ['one', 'two']);
    },
  );
}
