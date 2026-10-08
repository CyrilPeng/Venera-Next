import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/favorites/favorite_metadata_update.dart';
import 'package:venera_next/features/favorites/favorite_models.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/operation_failure.dart';
import 'package:venera_next/foundation/persistence_failure.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/network/request_scope.dart';

FavoriteItem _item(String id) => FavoriteItem.withTime(
  id: id,
  name: 'original',
  author: 'old author',
  type: const ComicType(17),
  tags: ['old tag'],
  coverPath: 'old cover',
  time: 'legacy: untouched',
);
ComicDetails _details(String id, {String? subtitle, List<String>? authors}) =>
    ComicDetails.fromJson({
      'title': 'new $id',
      'subtitle': subtitle,
      'cover': 'new cover',
      'sourceKey': 'synthetic',
      'comicId': 'untrusted returned id',
      'tags': {
        'author': ?authors,
        'ARTIST': ['ignored'],
        'Time': ['ignored'],
        'Genre': ['one', 'two'],
      },
    });
Future<void> _turn() => Future<void>.delayed(Duration.zero);

void main() {
  for (final mode in ['subtitle', 'author', 'original']) {
    test(
      'metadata preserves storage identity and mapping with $mode author',
      () async {
        final original = _item('A');
        final writes = <FavoriteItem>[];
        final update = FavoriteMetadataUpdate(
          comics: [original],
          load: (item) async {
            item.id = 'mutated input';
            item.tags.add('mutated tag');
            return Res(
              _details(
                'A',
                subtitle: mode == 'subtitle' ? 'subtitle' : null,
                authors: mode == 'original' ? [] : ['author'],
              ),
            );
          },
          save: (item) async => writes.add(item),
          checkActive: () {},
        );
        original.id = 'changed after construction';
        final result = await update.run();
        final value = writes.single;
        expect(value.id, 'A');
        expect(value.type, const ComicType(17));
        expect(value.time, 'legacy: untouched');
        expect(value.name, 'new A');
        expect(value.coverPath, 'new cover');
        expect(value.tags, ['Genre:one', 'Genre:two']);
        expect(value.author, mode == 'original' ? 'old author' : mode);
        expect(result.progress, (
          total: 1,
          completed: 1,
          updated: 1,
          failed: 0,
        ));
        expect(result.cancelled, isFalse);
        expect(original.tags, ['old tag']);
      },
    );
  }

  test(
    'empty metadata operation completes once without loading or saving',
    () async {
      final operation = FavoriteMetadataUpdate(
        comics: [],
        load: (_) => throw StateError('Unexpected load'),
        save: (_) => throw StateError('Unexpected save'),
        checkActive: () {},
      );
      final first = operation.run();
      expect(identical(first, operation.run()), isTrue);
      final result = await first;
      expect(result.progress, (total: 0, completed: 0, updated: 0, failed: 0));
      expect(result.failures, isEmpty);
    },
  );

  test(
    'requests start in groups of four and await the whole previous group',
    () async {
      final calls = <String>[];
      final ready = {for (var i = 0; i < 9; i++) '$i': Completer<void>()};
      final operation = FavoriteMetadataUpdate(
        comics: [for (var i = 0; i < 9; i++) _item('$i')],
        load: (item) async {
          calls.add(item.id);
          await ready[item.id]!.future;
          return Res(_details(item.id));
        },
        save: (_) async {},
        checkActive: () {},
      );
      addTearDown(() {
        for (final value in ready.values) {
          if (!value.isCompleted) value.complete();
        }
      });
      final work = operation.run();
      await _turn();
      expect(calls, ['0', '1', '2', '3']);
      for (final id in ['1', '2', '3']) {
        ready[id]!.complete();
      }
      await _turn();
      expect(calls, ['0', '1', '2', '3']);
      ready['0']!.complete();
      await _turn();
      expect(calls, ['0', '1', '2', '3', '4', '5', '6', '7']);
      for (final id in ['4', '5', '6', '7']) {
        ready[id]!.complete();
      }
      await _turn();
      expect(calls.last, '8');
      ready['8']!.complete();
      expect((await work).progress.updated, 9);
    },
  );

  test(
    'ordinary load failures allow three attempts and preserve the last cause',
    () async {
      final error = StateError('source unavailable');
      final stack = StackTrace.fromString('original source stack');
      var calls = 0;
      final operation = FavoriteMetadataUpdate(
        comics: [_item('A')],
        load: (_) async {
          calls++;
          Error.throwWithStackTrace(error, stack);
        },
        save: (_) => throw StateError('Unexpected save'),
        checkActive: () {},
      );
      final result = await operation.run();
      expect(calls, 3);
      final failure = result.failures.single;
      expect(failure.id, 'A');
      expect(failure.type, 17);
      expect(failure.stage, FavoriteMetadataStage.load);
      expect(failure.cause, same(error));
      expect(failure.stackTrace.toString(), stack.toString());
      expect(failure.kind, FailureKind.failed);
    },
  );

  test(
    'a later successful load attempt saves once and a missing source skips',
    () async {
      var calls = 0;
      var writes = 0;
      final operation = FavoriteMetadataUpdate(
        comics: [_item('A'), _item('missing')],
        load: (item) async {
          if (item.id == 'missing') return null;
          calls++;
          if (calls < 3) throw StateError('retry');
          return Res(_details(item.id));
        },
        save: (_) async => writes++,
        checkActive: () {},
      );
      final result = await operation.run();
      expect(calls, 3);
      expect(writes, 1);
      expect(result.progress, (total: 2, completed: 2, updated: 1, failed: 0));
    },
  );

  for (final kind in [FailureKind.cancelled, FailureKind.unsupported]) {
    test(
      'structured source $kind is not retried as an ordinary error',
      () async {
        var calls = 0;
        final reason = OperationFailure(
          message: 'original source response',
          kind: kind,
        );
        final operation = FavoriteMetadataUpdate(
          comics: [_item('A')],
          load: (_) async {
            calls++;
            return Res.failure(reason);
          },
          save: (_) => throw StateError('Unexpected save'),
          checkActive: () {},
        );
        final result = await operation.run();
        expect(calls, 1);
        expect(result.cancelled, kind == FailureKind.cancelled);
        if (kind == FailureKind.cancelled) {
          expect(result.failures, isEmpty);
        } else {
          expect(result.failures.single.cause, same(reason));
          expect(result.failures.single.kind, FailureKind.unsupported);
        }
      },
    );
  }

  test('cancel before start avoids source and storage calls', () async {
    final operation = FavoriteMetadataUpdate(
      comics: [_item('A')],
      load: (_) => throw StateError('Unexpected load'),
      save: (_) => throw StateError('Unexpected save'),
      checkActive: () {},
    )..cancel();
    final result = await operation.run();
    expect(result.cancelled, isTrue);
    expect(result.progress.completed, 0);
  });

  test(
    'cancellation reaches a source scope but awaits its actual completion',
    () async {
      final release = Completer<void>();
      RequestScope? original;
      var writes = 0;
      final operation = FavoriteMetadataUpdate(
        comics: [_item('A')],
        load: (item) async {
          original = RequestScope.current;
          await release.future;
          return Res(_details(item.id));
        },
        save: (_) async => writes++,
        checkActive: () {},
      );
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      var ended = false;
      final work = operation.run().then((value) {
        ended = true;
        return value;
      });
      await _turn();
      expect(original, isNotNull);
      operation.cancel();
      await _turn();
      expect(original!.isCancelled, isTrue);
      expect(ended, isFalse);
      release.complete();
      final result = await work;
      expect(result.cancelled, isTrue);
      expect(result.failures, isEmpty);
      expect(writes, 0);
    },
  );

  test(
    'late encoded source failure survives cancellation and keeps its cause',
    () async {
      final release = Completer<void>();
      final error = StateError('actual source failure after cancellation');
      final stack = StackTrace.fromString('encoded original stack');
      final operation = FavoriteMetadataUpdate(
        comics: [_item('A')],
        load: (_) async {
          await release.future;
          return Res.fromException(error, stack);
        },
        save: (_) => throw StateError('Unexpected save'),
        checkActive: () {},
      );
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final work = operation.run();
      await _turn();
      operation.cancel();
      release.complete();
      final result = await work;
      expect(result.cancelled, isTrue);
      final failure = result.failures.single;
      expect((failure.cause as FailureDetails).cause, same(error));
      expect(failure.stackTrace.toString(), stack.toString());
      expect(failure.kind, FailureKind.failed);
    },
  );

  for (final state in PersistenceCommitState.values) {
    test('save failure $state never re-fetches or replays metadata', () async {
      var loads = 0;
      var writes = 0;
      final cause = StateError('storage publication');
      final failure = PersistenceFailure(
        commitState: state,
        cause: cause,
        stackTrace: StackTrace.current,
      );
      final operation = FavoriteMetadataUpdate(
        comics: [_item('A')],
        load: (item) async {
          loads++;
          return Res(_details(item.id));
        },
        save: (_) async {
          writes++;
          throw failure;
        },
        checkActive: () {},
      );
      final result = await operation.run();
      expect((loads, writes), (1, 1));
      expect(result.failures.single.cause, same(failure));
      expect(result.failures.single.stage, FavoriteMetadataStage.save);
      expect(
        result.progress.updated,
        state == PersistenceCommitState.committed ? 1 : 0,
      );
      expect(result.progress.failed, 1);
    });
  }

  test(
    'cancellation waits for an already accepted save and retains its success',
    () async {
      final release = Completer<void>();
      final started = Completer<void>();
      final operation = FavoriteMetadataUpdate(
        comics: [_item('A')],
        load: (item) async => Res(_details(item.id)),
        save: (_) async {
          started.complete();
          await release.future;
        },
        checkActive: () {},
      );
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      var ended = false;
      final work = operation.run().then((value) {
        ended = true;
        return value;
      });
      await started.future;
      operation.cancel();
      await _turn();
      expect(ended, isFalse);
      release.complete();
      final result = await work;
      expect(result.cancelled, isTrue);
      expect(result.progress.updated, 1);
      expect(result.failures, isEmpty);
    },
  );

  test(
    'progress failure cancels new work and still drains every accepted read',
    () async {
      final ready = {for (var i = 0; i < 5; i++) '$i': Completer<void>()};
      final calls = <String>[];
      final error = StateError('progress observer failed');
      final operation = FavoriteMetadataUpdate(
        comics: [for (var i = 0; i < 5; i++) _item('$i')],
        load: (item) async {
          calls.add(item.id);
          await ready[item.id]!.future;
          return Res(_details(item.id));
        },
        save: (_) async {},
        checkActive: () {},
        onProgress: (progress) {
          if (progress.completed == 1) throw error;
        },
      );
      addTearDown(() {
        for (final value in ready.values) {
          if (!value.isCompleted) value.complete();
        }
      });
      var ended = false;
      final work = operation.run();
      final observed = work.then<void>(
        (_) => ended = true,
        onError: (Object failure) {
          expect(failure, same(error));
          ended = true;
        },
      );
      await _turn();
      ready['0']!.complete();
      await _turn();
      expect(ended, isFalse);
      for (final id in ['1', '2', '3']) {
        ready[id]!.complete();
      }
      await observed;
      expect(calls, ['0', '1', '2', '3']);
    },
  );
}
