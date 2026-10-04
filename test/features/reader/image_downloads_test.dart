import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/image_downloads.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/network/image_loading_config.dart';
import 'package:venera_next/network/image_stream.dart';
import 'package:venera_next/network/images.dart';
import 'package:venera_next/network/shared_image_requests.dart';

void main() {
  ImageWork work() {
    final owner = ImageWork();
    addTearDown(owner.dispose);
    return owner;
  }

  test('deduplicates locally and preserves other shared consumers', () async {
    final requests = SharedImageRequests<ImageDownloadProgress>();
    addTearDown(requests.cancelAll);
    var loads = 0;
    var cancels = 0;
    final source = StreamController<ImageDownloadProgress>(
      onCancel: () => cancels++,
    );
    Stream<ImageDownloadProgress> load(
      String image,
      String? sourceKey,
      String cid,
      String eid,
    ) => requests.open((_) {
      loads++;
      return source.stream;
    }, key: (image, sourceKey, cid, eid));
    final first = ReaderImageDownloads(work: work(), loader: load);
    final second = ReaderImageDownloads(work: work(), loader: load);
    first.preload('image', 'source', 'comic', 'chapter');
    first.preload('image', 'source', 'comic', 'chapter');
    second.preload('image', 'source', 'comic', 'chapter');
    final events = <ImageDownloadProgress>[];
    final visible = load(
      'image',
      'source',
      'comic',
      'chapter',
    ).listen(events.add);
    expect(loads, 1);
    await first.dispose();
    await second.dispose();
    expect(cancels, 0);
    source.add(const ImageDownloadProgress(currentBytes: 1, totalBytes: 2));
    await pumpEventQueue();
    expect(events, hasLength(1));
    await visible.cancel();
    expect(cancels, 1);
    await source.close();
  });

  test(
    'holds stop admission and a disposed view leaves its session usable',
    () async {
      final session = work();
      var loads = 0;
      final streams = <StreamController<ImageDownloadProgress>>[];
      final owner = ReaderImageDownloads(
        work: session,
        loader: (_, _, _, _) {
          loads++;
          final stream = StreamController<ImageDownloadProgress>();
          streams.add(stream);
          return stream.stream;
        },
      );
      final release = session.holdForExit();
      owner.preload('image', null, 'comic', 'chapter');
      expect(loads, 0);
      release();
      owner.preload('file://local.png', null, 'comic', 'chapter');
      expect(loads, 0);
      owner.preload('image', null, 'comic', 'chapter');
      expect(loads, 1);
      final closing = owner.dispose();
      expect(owner.dispose(), same(closing));
      await closing;
      owner.preload('another', null, 'comic', 'chapter');
      expect(loads, 1);
      final task = session.start();
      expect(task, isNotNull);
      task!.finish();
      for (final stream in streams) {
        await stream.close();
      }
    },
  );

  test(
    'session and view both wait for the last subscription cleanup',
    () async {
      final session = work();
      final cleanup = Completer<void>();
      var cancellations = 0;
      final source = StreamController<ImageDownloadProgress>(
        onCancel: () {
          cancellations++;
          return cleanup.future;
        },
      );
      final owner = ReaderImageDownloads(
        work: session,
        loader: (_, _, _, _) => source.stream,
      );
      owner.preload('image', null, 'comic', 'chapter');
      var prepared = false;
      final preparing = session.prepareForExit().then((release) {
        prepared = true;
        return release;
      });
      var disposed = false;
      final closing = owner.dispose().then((_) => disposed = true);
      await pumpEventQueue();
      expect(cancellations, 1);
      expect(prepared, isFalse);
      expect(disposed, isFalse);
      cleanup.complete();
      await closing;
      (await preparing)();
      expect(prepared, isTrue);
      await source.close();
    },
  );

  test(
    'normal completion waits for cleanup before retrying the same image',
    () async {
      final session = work();
      final cleanup = Completer<void>();
      final streams = <StreamController<ImageDownloadProgress>>[];
      final owner = ReaderImageDownloads(
        work: session,
        loader: (_, _, _, _) {
          final stream = StreamController<ImageDownloadProgress>(
            onCancel: streams.isEmpty ? () => cleanup.future : null,
          );
          streams.add(stream);
          return stream.stream;
        },
      );
      owner.preload('image', null, 'comic', 'chapter');
      streams.first.add(
        ImageDownloadProgress(
          currentBytes: 1,
          totalBytes: 1,
          imageBytes: Uint8List(1),
        ),
      );
      await pumpEventQueue();
      owner.preload('image', null, 'comic', 'chapter');
      expect(streams, hasLength(1));
      cleanup.complete();
      await pumpEventQueue();
      owner.preload('image', null, 'comic', 'chapter');
      expect(streams, hasLength(2));
      await owner.dispose();
      for (final stream in streams) {
        await stream.close();
      }
    },
  );

  test(
    'ordinary failed samples release their key and can be retried',
    () async {
      final session = work();
      final streams = <StreamController<ImageDownloadProgress>>[];
      final owner = ReaderImageDownloads(
        work: session,
        loader: (_, _, _, _) {
          final stream = StreamController<ImageDownloadProgress>();
          streams.add(stream);
          return stream.stream;
        },
      );
      owner.preload('image', null, 'comic', 'chapter');
      streams.first.addError(StateError('offline'));
      await pumpEventQueue();
      owner.preload('image', null, 'comic', 'chapter');
      expect(streams, hasLength(2));
      await owner.dispose();
      (await session.prepareForExit())();
      for (final stream in streams) {
        await stream.close();
      }
    },
  );

  for (final beforeDisposal in [false, true]) {
    test('cleanup failure survives retirement=$beforeDisposal', () async {
      final session = work();
      final cleanup = Completer<void>();
      final error = StateError('native cleanup');
      final stack = StackTrace.fromString('original cleanup stack');
      final source = StreamController<ImageDownloadProgress>(
        onCancel: () => cleanup.future,
      );
      final owner = ReaderImageDownloads(
        work: session,
        loader: (_, _, _, _) => source.stream,
      );
      owner.preload('image', null, 'comic', 'chapter');
      if (beforeDisposal) {
        source.add(
          ImageDownloadProgress(
            currentBytes: 1,
            totalBytes: 1,
            imageBytes: Uint8List(1),
          ),
        );
        await pumpEventQueue();
        cleanup.completeError(error, stack);
        await pumpEventQueue();
      }
      final observed = expectLater(
        session.prepareForExit(),
        throwsA(
          isA<ImageWorkFailure>().having(
            (failure) => failure.failures.single.error,
            'cleanup retains original cause',
            isA<ImageStreamCleanupFailure>().having(
              (failure) => failure.failures.last,
              'original cleanup and stack',
              (stage: 'subscription cancellation', error: error, stack: stack),
            ),
          ),
        ),
      );
      if (!beforeDisposal) {
        await pumpEventQueue();
        cleanup.completeError(error, stack);
      }
      await observed;
      await owner.dispose();
      (await session.prepareForExit())();
      await source.close();
    });
  }

  test(
    'structured source cleanup failures survive completed download removal',
    () async {
      final session = work();
      final error = StateError('release source references');
      final stack = StackTrace.fromString('source references stack');
      final failure = ImageLoadingConfigCleanupFailure([
        (error: error, stack: stack),
      ]);
      final owner = ReaderImageDownloads(
        work: session,
        loader: (_, _, _, _) => Stream.error(failure, stack),
      );
      owner.preload('image', null, 'comic', 'chapter');
      await pumpEventQueue();
      await owner.dispose();
      await expectLater(
        session.prepareForExit(),
        throwsA(
          isA<ImageWorkFailure>().having(
            (result) => result.failures.single.error,
            'source failure',
            same(failure),
          ),
        ),
      );
    },
  );

  test(
    'source and cleanup failures both reach the session after retirement',
    () async {
      final session = work();
      final sourceError = StateError('offline with unfinished native cleanup');
      final sourceStack = StackTrace.fromString('source failure stack');
      final cleanupError = StateError('native release failed');
      final cleanupStack = StackTrace.fromString('native release stack');
      final source = StreamController<ImageDownloadProgress>(
        onCancel: () => Future<void>.error(cleanupError, cleanupStack),
      );
      final owner = ReaderImageDownloads(
        work: session,
        loader: (_, _, _, _) => source.stream,
      );
      owner.preload('image', null, 'comic', 'chapter');
      source.addError(sourceError, sourceStack);
      await pumpEventQueue();
      await owner.dispose();
      await expectLater(
        session.prepareForExit(),
        throwsA(
          isA<ImageWorkFailure>().having(
            (result) => result.failures.single.error,
            'both original errors',
            isA<ImageStreamCleanupFailure>().having(
              (failure) => failure.failures,
              'failure stages and original stacks',
              [
                (stage: 'read', error: sourceError, stack: sourceStack),
                (
                  stage: 'subscription cancellation',
                  error: cleanupError,
                  stack: cleanupStack,
                ),
              ],
            ),
          ),
        ),
      );
      await source.close();
    },
  );

  test(
    'reentrant cancellation during listen joins the first cancel future',
    () async {
      final session = work();
      final cleanup = Completer<void>();
      void Function()? release;
      final source = StreamController<ImageDownloadProgress>(
        onListen: () => release = session.holdForExit(),
        onCancel: () => cleanup.future,
      );
      final owner = ReaderImageDownloads(
        work: session,
        loader: (_, _, _, _) => source.stream,
      );
      owner.preload('image', null, 'comic', 'chapter');
      var closed = false;
      final closing = owner.dispose().then((_) => closed = true);
      await pumpEventQueue();
      expect(closed, isFalse);
      cleanup.complete();
      await closing;
      release!();
      await source.close();
    },
  );
}
