import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_details/thumbnail_pages.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/network/request_scope.dart';

void main() {
  test(
    'pages reserve once, preserve cursor order and freeze borrowed lists',
    () async {
      final initial = ['one'];
      final pending = Completer<Res<List<String>>>();
      final cursors = <String?>[];
      final events = <String>[];
      final pages = ComicThumbnailPages(
        comicId: 'id',
        initial: initial,
        canLoad: () => true,
        retain: (scope, settled) {
          events.add('retain');
          return () => events.add('release');
        },
        onChanged: () => events.add('changed'),
        load: (id, next) {
          cursors.add(next);
          return pending.future;
        },
      );
      initial.add('external');
      final first = pages.loadNext();
      expect(pages.loadNext(), same(first));
      expect(pages.isLoading, isTrue);
      expect(events.first, 'retain');
      expect(cursors, isEmpty);
      await pumpEventQueue();
      expect(cursors, [null]);
      final response = ['two', 'two'];
      pending.complete(Res(response, subData: ''));
      await first;
      response.clear();
      expect(pages.items, ['one', 'two', 'two']);
      expect(() => pages.items.add('no'), throwsUnsupportedError);
      expect(pages.hasMore, isTrue);
      await pages.loadNext();
      expect(cursors, [null, '']);
      expect(events.where((e) => e == 'release'), hasLength(2));
      await pages.closeAndWait();
    },
  );
  test(
    'a failed page retries its cursor and does not append invalid data',
    () async {
      var call = 0;
      final cursors = <String?>[];
      final cause = StateError('offline');
      final stack = StackTrace.current;
      final pages = ComicThumbnailPages(
        comicId: 'id',
        initial: ['initial'],
        canLoad: () => true,
        retain: (_, _) => () {},
        onChanged: () {},
        load: (id, next) async {
          cursors.add(next);
          switch (++call) {
            case 1:
              return const Res(['page'], subData: 'cursor');
            case 2:
              Error.throwWithStackTrace(cause, stack);
            case 3:
              return const Res(['invalid'], subData: 7);
            default:
              return const Res(['last']);
          }
        },
      );
      await pages.loadNext();
      await pages.loadNext();
      expect(pages.failure!.failure!.cause, same(cause));
      expect(pages.failure!.failure!.stackTrace, same(stack));
      await pages.loadNext();
      expect(pages.items, ['initial', 'page']);
      expect(pages.failure!.failure!.cause, isA<FormatException>());
      await pages.loadNext();
      expect(cursors, [null, 'cursor', 'cursor', 'cursor']);
      expect(pages.items, ['initial', 'page', 'last']);
      expect(pages.failure, isNull);
      expect(pages.hasMore, isFalse);
      await pages.loadNext();
      expect(call, 4);
      await pages.closeAndWait();
    },
  );
  for (final throwsError in [false, true]) {
    test(
      'retirement joins the actual read and preserves late failure: $throwsError',
      () async {
        final pending = Completer<Res<List<String>>>();
        late RequestScope scope;
        var changed = 0, released = false;
        final cause = StateError('late failure');
        final stack = StackTrace.current;
        final pages = ComicThumbnailPages(
          comicId: 'id',
          initial: ['initial'],
          canLoad: () => true,
          retain: (s, _) {
            scope = s;
            return () => released = true;
          },
          onChanged: () => changed++,
          load: (_, _) => pending.future,
        );
        final read = pages.loadNext();
        await pumpEventQueue();
        final close = pages.closeAndWait();
        expect(close, same(read));
        expect(scope.isCancelled, isTrue);
        expect(released, isFalse);
        final notifications = changed;
        if (throwsError) {
          pending.completeError(cause, stack);
        } else {
          pending.complete(Res.fromException(cause, stack));
        }
        await close;
        expect(pages.failure!.failure!.cause, same(cause));
        expect(pages.items, ['initial']);
        expect(changed, notifications);
        expect(released, isTrue);
      },
    );
  }
  test(
    'registration can synchronously close before the loader starts',
    () async {
      var calls = 0;
      late ComicThumbnailPages pages;
      Future<void>? closing;
      pages = ComicThumbnailPages(
        comicId: 'id',
        initial: [],
        canLoad: () => true,
        retain: (_, _) {
          closing = pages.closeAndWait();
          return () {};
        },
        onChanged: () {},
        load: (_, _) async {
          calls++;
          return const Res([]);
        },
      );
      await pages.loadNext();
      await closing;
      expect(calls, 0);
      expect(pages.isLoading, isFalse);
    },
  );
  test(
    'host cancellation can be retried with the same cursor after recovery',
    () async {
      final pending = Completer<Res<List<String>>>();
      RequestScope? scope;
      var calls = 0;
      final pages = ComicThumbnailPages(
        comicId: 'id',
        initial: [],
        canLoad: () => true,
        retain: (s, _) {
          scope = s;
          return () {};
        },
        onChanged: () {},
        load: (_, _) {
          calls++;
          return calls == 1
              ? pending.future
              : Future.value(const Res(['retry']));
        },
      );
      final read = pages.loadNext();
      await pumpEventQueue();
      scope!.cancel();
      pending.complete(const Res(['stale']));
      await read;
      expect(pages.items, isEmpty);
      expect(pages.failure, isNotNull);
      await pages.loadNext();
      expect(pages.items, ['retry']);
      await pages.closeAndWait();
    },
  );
  test('closed admission and absent loaders do not register work', () async {
    for (final enabled in [false, true]) {
      final pages = ComicThumbnailPages(
        comicId: 'id',
        initial: ['initial'],
        canLoad: () => enabled,
        retain: (_, _) => throw StateError('not admitted'),
        onChanged: () {},
        load: enabled ? null : (_, _) async => const Res([]),
      );
      await pages.loadNext();
      expect(pages.isLoading, isFalse);
      expect(pages.failure, isNull);
      await pages.closeAndWait();
    }
  });
}
