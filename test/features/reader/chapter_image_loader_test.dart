import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/chapter_image_loader.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/features/reader/waterfall_controller.dart';
import 'package:venera_next/features/reader/waterfall_flow.dart';
import 'package:venera_next/network/request_scope.dart';

void main() {
  ChapterImageLoader loader({
    Future<List<String>> Function()? local,
    Future<List<String>> Function()? online,
    void Function(FileSystemException, StackTrace)? failure,
  }) => ChapterImageLoader(
    readLocal: local,
    loadOnline: online,
    localPath: '/book',
    onLocalFailure: failure ?? (_, _) {},
    localUnavailable: (path) => FileSystemException('repair', path),
    sourceUnavailable: StateError('source unavailable'),
  );

  test(
    'local success avoids online access and keeps original image order',
    () async {
      var onlineCalls = 0;
      final service = loader(
        local: () async => ['2.jpg', '1.jpg'],
        online: () async {
          onlineCalls++;
          return ['remote'];
        },
      );
      expect(await service.load(), ['2.jpg', '1.jpg']);
      expect(onlineCalls, 0);
    },
  );

  test(
    'missing and empty local files notify recovery only after online success',
    () async {
      for (final empty in [true, false]) {
        var failures = 0;
        var recovered = 0;
        final service = loader(
          local: () async {
            if (empty) return [];
            throw const FileSystemException('missing', '/gone');
          },
          online: () async => ['online.jpg'],
          failure: (_, _) => failures++,
        );
        expect(await service.load(onOnlineFallback: () => recovered++), [
          'online.jpg',
        ]);
        expect(failures, 1);
        expect(recovered, 1);
      }
    },
  );

  test('unavailable storage and source expose distinct errors', () async {
    await expectLater(
      loader(local: () async => []).load(),
      throwsA(
        isA<FileSystemException>().having((e) => e.path, 'path', '/book'),
      ),
    );
    await expectLater(loader().load(), throwsStateError);
    var recovered = false;
    await expectLater(
      loader(
        local: () async => [],
        online: () async => throw StateError('offline'),
      ).load(onOnlineFallback: () => recovered = true),
      throwsStateError,
    );
    expect(recovered, false);
  });

  test(
    'non-filesystem failures do not silently trigger online fallback',
    () async {
      var called = false;
      await expectLater(
        loader(
          local: () async => throw StateError('database'),
          online: () async {
            called = true;
            return [];
          },
        ).load(),
        throwsStateError,
      );
      expect(called, false);
    },
  );

  test(
    'cancelled local read cannot log, recover or start online work',
    () async {
      final pending = Completer<List<String>>();
      final owner = RequestScope();
      var effects = 0;
      final service = loader(
        local: () => pending.future,
        online: () async {
          effects++;
          return [];
        },
        failure: (_, _) => effects++,
      );
      final failure = const FileSystemException('late missing');
      var settled = false;
      final expectation = expectLater(
        service.load(scope: owner, onOnlineFallback: () => effects++),
        throwsA(same(failure)),
      ).then((_) => settled = true);
      owner.cancel();
      await pumpEventQueue();
      expect(settled, false);
      pending.completeError(failure);
      await expectation;
      expect(effects, 0);
      owner.dispose();
    },
  );

  test(
    'cancelled local success waits for the read and skips fallback',
    () async {
      final pending = Completer<List<String>>();
      final owner = RequestScope();
      late RequestScope child;
      var settled = false;
      var effects = 0;
      final service = loader(
        local: () {
          child = RequestScope.current!;
          return pending.future;
        },
        online: () async {
          effects++;
          return ['remote'];
        },
        failure: (_, _) => effects++,
      );
      final expected = expectLater(
        service.load(scope: owner, onOnlineFallback: () => effects++),
        throwsA(isA<RequestCancelled>()),
      ).then((_) => settled = true);
      owner.cancel();
      await pumpEventQueue();
      expect(child.cancelToken.isCancelled, true);
      expect(settled, false);
      pending.complete(['local']);
      await expected;
      expect(effects, 0);
      owner.dispose();
    },
  );

  test(
    'cancelled online failure retains identity and stack after fallback',
    () async {
      final pending = Completer<List<String>>();
      final onlineStarted = Completer<RequestScope>();
      final owner = RequestScope();
      final failure = StateError('late online error');
      final stack = StackTrace.fromString('original online stack');
      var recovered = false;
      final result = loader(
        local: () async => [],
        online: () {
          onlineStarted.complete(RequestScope.current!);
          return pending.future;
        },
      ).load(scope: owner, onOnlineFallback: () => recovered = true);
      final checked = result.then<void>(
        (_) => fail('unexpected success'),
        onError: (Object error, StackTrace actualStack) {
          expect(error, same(failure));
          expect(actualStack, same(stack));
        },
      );
      final child = await onlineStarted.future;
      owner.cancel();
      expect(child.cancelToken.isCancelled, true);
      pending.completeError(failure, stack);
      await checked;
      expect(recovered, false);
      owner.dispose();
    },
  );

  for (final failRead in [false, true]) {
    test(
      'waterfall exit joins the original local read; failure=$failRead',
      () async {
        final work = ImageWork();
        final pending = Completer<List<String>>();
        final failure = const FileSystemException('late local read failure');
        final controller =
            WaterfallController(
              maxChapter: 2,
              imageWork: work,
              load: (_, scope) =>
                  loader(local: () => pending.future).load(scope: scope),
              chapterId: (chapter) => '$chapter',
              onChanged: () {},
              onPreviousError: (_, _) => fail('unexpected UI error'),
            )..initialize(
              WaterfallChapterSegment(chapter: 1, eid: '1', images: ['first']),
            );
        final loading = controller.ensureAfter(current: 1, threshold: 1);
        var prepared = false;
        final preparation = work.prepareForExit();
        final checked = failRead
            ? expectLater(
                preparation,
                throwsA(
                  isA<ImageWorkFailure>().having(
                    (error) => error.failures.map((entry) => entry.error),
                    'original local error',
                    [failure],
                  ),
                ),
              ).then((_) => prepared = true)
            : preparation.then((release) {
                prepared = true;
                release();
              });
        await loading;
        await pumpEventQueue();
        expect(prepared, false);
        if (failRead) {
          pending.completeError(failure);
        } else {
          pending.complete(['late local page']);
        }
        await checked;
        expect(controller.flow.lastChapter, 1);
        expect(controller.afterError, isNull);
        await controller.dispose();
      },
    );
  }
}
