import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/chapter_image_loader.dart';
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
      final expectation = expectLater(
        service.load(scope: owner, onOnlineFallback: () => effects++),
        throwsA(isA<RequestCancelled>()),
      );
      owner.cancel();
      await expectation;
      pending.completeError(const FileSystemException('late missing'));
      await pumpEventQueue();
      expect(effects, 0);
      owner.dispose();
    },
  );
}
