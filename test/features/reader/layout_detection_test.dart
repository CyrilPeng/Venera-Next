import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:venera_next/features/reader/layout_detection.dart';
import 'package:venera_next/foundation/comic_layout.dart';
import 'package:venera_next/network/image_http_client.dart';
import 'package:venera_next/network/image_loading_config.dart';
import 'package:venera_next/network/images.dart';
import 'package:venera_next/network/shared_image_requests.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final page = image.encodePng(image.Image(width: 20, height: 30));
  final strip = image.encodePng(image.Image(width: 20, height: 80));
  final images = List.generate(9, (i) => 'https://example.invalid/$i.png');
  late Stream<ImageDownloadProgress> Function(String, String?, String, String)
  loader;
  final expectedFailures = <ComicLayoutProbe>{};

  Future<ComicLayoutDetection> detect(
    ComicLayoutProbe probe, [
    List<String>? urls,
  ]) => probe.detect(
    images: urls ?? images,
    sourceKey: 'source',
    comicId: 'comic',
    chapterId: 'chapter',
  );
  ImageDownloadProgress event(Uint8List data) => ImageDownloadProgress(
    currentBytes: data.length,
    totalBytes: data.length,
    imageBytes: data,
  );
  Stream<ImageDownloadProgress> bytes(Uint8List data) =>
      Stream.value(event(data));

  ComicLayoutProbe createProbe({
    Future<ui.ImmutableBuffer> Function(Uint8List)? createBuffer,
    Future<ui.ImageDescriptor> Function(ui.ImmutableBuffer)? createDescriptor,
  }) {
    final probe = ComicLayoutProbe(
      loader: loader,
      createBuffer: createBuffer,
      createDescriptor: createDescriptor,
    );
    addTearDown(() async {
      probe.cancel();
      try {
        await probe.done;
      } on ComicLayoutProbeFailure {
        if (!expectedFailures.remove(probe)) rethrow;
      }
    });
    return probe;
  }

  Future<void> expectDoneFailure(ComicLayoutProbe probe, Matcher matcher) {
    expectedFailures.add(probe);
    return expectLater(probe.done, throwsA(matcher));
  }

  setUp(() => loader = (_, _, _, _) => bytes(page));

  test(
    'skips cover, samples six originals and forwards comic identity',
    () async {
      final loaded = <String>[];
      loader = (url, source, comic, chapter) {
        expect((source, comic, chapter), ('source', 'comic', 'chapter'));
        loaded.add(url);
        return bytes(page);
      };
      final probe = createProbe();
      final done = probe.done;
      var finished = false;
      unawaited(done.then((_) => finished = true));
      final result = await detect(probe);
      expect(finished, isTrue);
      expect(probe.done, same(done));
      expect(probe.isCancelled, isFalse);
      expect(result.layout, ComicLayout.paged);
      expect(result.sampleCount, 6);
      expect(loaded, images.sublist(1, 7));
    },
  );

  test(
    'repeated detect calls share one result and do not start new samples',
    () async {
      var loads = 0;
      loader = (_, _, _, _) {
        loads++;
        return bytes(page);
      };
      final probe = createProbe();
      final first = detect(probe);
      expect(detect(probe, ['different']), same(first));
      await first;
      expect(detect(probe), same(first));
      expect(loads, 6);
    },
  );

  test(
    'cancel before detect completes both futures without starting work',
    () async {
      loader = (_, _, _, _) => throw StateError('Unexpected download');
      final probe = createProbe();
      final done = probe.done;
      probe.cancel();
      probe.cancel();
      expect(probe.isCancelled, isTrue);
      expect((await detect(probe)).layout, ComicLayout.unknown);
      await done;
      expect(probe.done, same(done));
    },
  );

  test(
    'cancellation during listen still joins the first subscription cleanup',
    () async {
      final cleanup = Completer<void>();
      late ComicLayoutProbe probe;
      var loads = 0;
      var cancellations = 0;
      loader = (_, _, _, _) {
        loads++;
        return StreamController<ImageDownloadProgress>(
          onListen: () => probe.cancel(),
          onCancel: () {
            cancellations++;
            return cleanup.future;
          },
        ).stream;
      };
      probe = createProbe();
      expect((await detect(probe)).layout, ComicLayout.unknown);
      var finished = false;
      unawaited(probe.done.then((_) => finished = true));
      await pumpEventQueue();
      expect(finished, isFalse);
      expect(loads, 1);
      expect(cancellations, 1);
      cleanup.complete();
      await probe.done;
    },
  );

  test('fewer than four body images do not start downloads', () async {
    loader = (_, _, _, _) => throw StateError('Unexpected download');
    expect(
      (await detect(createProbe(), images.take(4).toList())).layout,
      ComicLayout.unknown,
    );
  });

  test('failed and corrupt samples still classify valid originals', () async {
    loader = (url, _, _, _) {
      if (url == images[1]) return Stream.error(StateError('offline'));
      if (url == images[2]) return bytes(Uint8List.fromList([1, 2, 3]));
      return bytes(strip);
    };
    final result = await detect(createProbe());
    expect(result.layout, ComicLayout.longStrip);
    expect(result.sampleCount, 4);
  });

  test(
    'all failed downloads fall back to unknown without lifetime failure',
    () async {
      loader = (_, _, _, _) => Stream.error(StateError('offline'));
      final result = await detect(createProbe());
      expect(result.layout, ComicLayout.unknown);
      expect(result.sampleCount, 0);
    },
  );

  for (final kind in ['HTTP', 'config', 'wrapped config']) {
    test(
      '$kind cleanup errors from stream events cannot become valid samples',
      () async {
        final stack = StackTrace.fromString('$kind cleanup event stack');
        final cause = StateError('cleanup');
        final configFailure = ImageLoadingConfigCleanupFailure([
          (error: cause, stack: stack),
        ]);
        final failure = switch (kind) {
          'HTTP' => ImageHttpCleanupFailure(
            cause: null,
            stackTrace: stack,
            failures: [(stage: 'close', error: cause, stack: stack)],
          ),
          'config' => configFailure,
          _ => ImageLoadingConfigFailure(
            cause: StateError('source error'),
            stackTrace: stack,
            cleanupFailure: configFailure,
          ),
        };
        loader = (url, _, _, _) =>
            url == images[1] ? Stream.error(failure, stack) : bytes(page);
        final probe = createProbe();
        final matcher = isA<ComicLayoutProbeFailure>().having(
          (e) => e.failures,
          'original cleanup failure',
          [(stage: 'read', error: failure, stack: stack)],
        );
        final done = expectDoneFailure(probe, matcher);
        await expectLater(detect(probe), throwsA(matcher));
        await done;
      },
    );
  }

  test('cleanup error after image bytes is still retained', () async {
    final stack = StackTrace.fromString('cleanup event after bytes stack');
    final failure = ImageLoadingConfigCleanupFailure([
      (error: StateError('release refs'), stack: stack),
    ]);
    loader = (_, _, _, _) {
      late StreamController<ImageDownloadProgress> stream;
      stream = StreamController<ImageDownloadProgress>(
        onListen: () {
          stream.add(event(page));
          stream.addError(failure, stack);
        },
      );
      return stream.stream;
    };
    final probe = createProbe();
    final matcher = isA<ComicLayoutProbeFailure>()
        .having((e) => e.failures, 'all errors after bytes', hasLength(6))
        .having(
          (e) => e.failures,
          'cleanup errors',
          everyElement((stage: 'read', error: failure, stack: stack)),
        );
    final done = expectDoneFailure(probe, matcher);
    await expectLater(detect(probe), throwsA(matcher));
    await done;
  });

  for (final layout in [ComicLayout.paged, ComicLayout.longStrip]) {
    test('classifies real local $layout images with original paths', () async {
      final directory = await Directory.systemTemp.createTemp('venera-layout-');
      addTearDown(() => directory.delete(recursive: true));
      final chapter = await Directory('${directory.path}/中文 扫描 # %20').create();
      final urls = <String>[];
      for (var i = 0; i < 7; i++) {
        final file = File('${chapter.path}/正文 $i.png');
        final isStrip = i == 0
            ? layout == ComicLayout.paged
            : layout == ComicLayout.longStrip;
        await file.writeAsBytes(isStrip ? strip : page);
        urls.add('file://${file.path}');
      }
      loader = (_, _, _, _) => throw StateError('Local image started download');
      final result = await detect(createProbe(), urls);
      expect(result.layout, layout);
      expect(result.sampleCount, 6);
    });
  }

  test(
    'two-sample limit includes native work and subscription cleanup',
    () async {
      final streams = <StreamController<ImageDownloadProgress>>[];
      final cancellations = <Completer<void>>[];
      var active = 0;
      var peak = 0;
      loader = (_, _, _, _) {
        final cleanup = Completer<void>();
        cancellations.add(cleanup);
        final stream = StreamController<ImageDownloadProgress>(
          onListen: () {
            active++;
            if (active > peak) peak = active;
          },
          onCancel: () async {
            await cleanup.future;
            active--;
          },
        );
        streams.add(stream);
        return stream.stream;
      };
      final probe = createProbe();
      final result = detect(probe);
      await pumpEventQueue();
      expect(streams, hasLength(2));
      streams.first.add(event(page));
      await pumpEventQueue();
      expect(streams, hasLength(2));
      cancellations.first.complete();
      await pumpEventQueue();
      expect(streams, hasLength(3));
      expect(peak, 2);
      probe.cancel();
      expect((await result).layout, ComicLayout.unknown);
      var finished = false;
      unawaited(probe.done.then((_) => finished = true));
      await pumpEventQueue();
      expect(finished, isFalse);
      for (final cleanup in cancellations.skip(1)) {
        cleanup.complete();
      }
      await probe.done;
      expect(active, 0);
      expect(streams, hasLength(3));
      for (final stream in streams) {
        await stream.close();
      }
    },
  );

  for (final failure in <Object?>[
    null,
    StateError('late file read'),
    const FileSystemException('late file read'),
  ]) {
    final failRead = failure != null;
    test(
      'cancelled local reads finish only after original ${failRead ? failure.runtimeType : 'bytes'}',
      () async {
        final reads = <Completer<Uint8List>>[];
        final stack = StackTrace.fromString('late local read stack');
        await IOOverrides.runZoned(
          () async {
            final probe = createProbe();
            final pending = detect(
              probe,
              List.generate(7, (i) => 'file:///scan-$i.png'),
            );
            await pumpEventQueue();
            expect(reads, hasLength(2));
            probe.cancel();
            expect((await pending).layout, ComicLayout.unknown);
            var finished = false;
            final observed = failRead
                ? expectDoneFailure(
                    probe,
                    isA<ComicLayoutProbeFailure>().having(
                      (e) => e.failures,
                      'late failures',
                      everyElement((
                        stage: 'read',
                        error: failure,
                        stack: stack,
                      )),
                    ),
                  )
                : probe.done;
            unawaited(observed.then((_) => finished = true));
            await pumpEventQueue();
            expect(finished, isFalse);
            for (final read in reads) {
              if (failRead) {
                read.completeError(failure, stack);
              } else {
                read.complete(page);
              }
            }
            await observed;
            expect(reads, hasLength(2));
          },
          createFile: (path) {
            expect(path, matches(r'^/scan-[1-6]\.png$'));
            return _PendingFile(path, page.length, reads);
          },
        );
      },
    );
  }

  testWidgets(
    'eight-second result budget does not complete pending cancellation',
    (tester) async {
      final cleanups = <Completer<void>>[];
      var cancels = 0;
      loader = (_, _, _, _) {
        final cleanup = Completer<void>();
        cleanups.add(cleanup);
        return StreamController<ImageDownloadProgress>(
          onCancel: () {
            cancels++;
            return cleanup.future;
          },
        ).stream;
      };
      // Keep the fake-clock lifetime inside the widget test. A package-level
      // teardown cannot pump Futures created in this fake async zone.
      final probe = ComicLayoutProbe(loader: loader);
      ComicLayoutDetection? result;
      unawaited(detect(probe).then((value) => result = value));
      var finished = false;
      unawaited(probe.done.then((_) => finished = true));
      await tester.pump(const Duration(milliseconds: 7999));
      expect(result, isNull);
      await tester.pump(const Duration(milliseconds: 1));
      expect(result!.layout, ComicLayout.unknown);
      expect(probe.isCancelled, isTrue);
      expect(cancels, 2);
      expect(finished, isFalse);
      probe.cancel();
      expect(cancels, 2);
      for (final cleanup in cleanups) {
        cleanup.complete();
      }
      await tester.pump();
      await probe.done;
    },
  );

  test(
    'first cancellation failures wait for every subscription and retain stacks',
    () async {
      final cleanups = <Completer<void>>[];
      var cancels = 0;
      loader = (_, _, _, _) {
        final cleanup = Completer<void>();
        cleanups.add(cleanup);
        return StreamController<ImageDownloadProgress>(
          onCancel: () {
            cancels++;
            return cleanup.future;
          },
        ).stream;
      };
      final probe = createProbe();
      final pending = detect(probe);
      await pumpEventQueue();
      probe.cancel();
      probe.cancel();
      expect((await pending).layout, ComicLayout.unknown);
      final error = StateError('cancel source');
      final stack = StackTrace.fromString('subscription cancellation stack');
      var finished = false;
      final observed = expectDoneFailure(
        probe,
        isA<ComicLayoutProbeFailure>().having(
          (e) => e.failures,
          'original cancellation failure',
          [(stage: 'subscription cancellation', error: error, stack: stack)],
        ),
      ).then((_) => finished = true);
      cleanups.first.completeError(error, stack);
      await pumpEventQueue();
      expect(finished, isFalse);
      cleanups.last.complete();
      await observed;
      expect(cancels, 2);
    },
  );

  test(
    'cleanup failure prevents an otherwise successful classification',
    () async {
      final failure = StateError('subscription cleanup');
      final stack = StackTrace.fromString('cleanup stack');
      loader = (_, _, _, _) {
        late StreamController<ImageDownloadProgress> stream;
        stream = StreamController<ImageDownloadProgress>(
          onListen: () => stream.add(event(strip)),
          onCancel: () => Future<void>.error(failure, stack),
        );
        return stream.stream;
      };
      final probe = createProbe();
      final matcher = isA<ComicLayoutProbeFailure>()
          .having((e) => e.failures, 'all cleanup failures', hasLength(6))
          .having(
            (e) => e.failures,
            'failure details',
            everyElement((
              stage: 'subscription cancellation',
              error: failure,
              stack: stack,
            )),
          );
      final done = expectDoneFailure(probe, matcher);
      await expectLater(detect(probe), throwsA(matcher));
      await done;
    },
  );

  test('stream data errors do not hide cancellation failure', () async {
    final failure = StateError('cancel after offline');
    final stack = StackTrace.fromString('cancel after error stack');
    loader = (_, _, _, _) {
      late StreamController<ImageDownloadProgress> stream;
      stream = StreamController<ImageDownloadProgress>(
        onListen: () => stream.addError(StateError('offline')),
        onCancel: () => Future<void>.error(failure, stack),
      );
      return stream.stream;
    };
    final probe = createProbe();
    final matcher = isA<ComicLayoutProbeFailure>().having(
      (e) => e.failures,
      'cancellation failure after data error',
      everyElement((
        stage: 'subscription cancellation',
        error: failure,
        stack: stack,
      )),
    );
    final done = expectDoneFailure(probe, matcher);
    await expectLater(detect(probe), throwsA(matcher));
    await done;
  });

  test(
    'cancellation waits for native buffers and does not create descriptors',
    () async {
      final pendingBuffers = <Completer<ui.ImmutableBuffer>>[];
      final allocated = <ui.ImmutableBuffer>[];
      var descriptors = 0;
      final probe = createProbe(
        createBuffer: (data) {
          final pending = Completer<ui.ImmutableBuffer>();
          pendingBuffers.add(pending);
          return pending.future;
        },
        createDescriptor: (buffer) {
          descriptors++;
          return ui.ImageDescriptor.encoded(buffer);
        },
      );
      final result = detect(probe);
      await pumpEventQueue();
      expect(pendingBuffers, hasLength(2));
      probe.cancel();
      expect((await result).layout, ComicLayout.unknown);
      var finished = false;
      unawaited(probe.done.then((_) => finished = true));
      await pumpEventQueue();
      expect(finished, isFalse);
      for (final pending in pendingBuffers) {
        final buffer = await ui.ImmutableBuffer.fromUint8List(page);
        allocated.add(buffer);
        pending.complete(buffer);
      }
      await probe.done;
      expect(descriptors, 0);
      expect(allocated.every((buffer) => buffer.debugDisposed), isTrue);
    },
  );

  for (final failDescriptor in [false, true]) {
    test(
      'late descriptor ${failDescriptor ? 'failure' : 'completion'} releases native buffers',
      () async {
        final buffers = <ui.ImmutableBuffer>[];
        final pending = <Completer<ui.ImageDescriptor>>[];
        final descriptors = <_Descriptor>[];
        final failure = StateError('late descriptor creation');
        final stack = StackTrace.fromString('late descriptor original stack');
        final probe = createProbe(
          createBuffer: (data) async {
            final buffer = await ui.ImmutableBuffer.fromUint8List(data);
            buffers.add(buffer);
            return buffer;
          },
          createDescriptor: (_) {
            final descriptor = Completer<ui.ImageDescriptor>();
            pending.add(descriptor);
            return descriptor.future;
          },
        );
        final result = detect(probe);
        await pumpEventQueue();
        expect(pending, hasLength(2));
        probe.cancel();
        expect((await result).layout, ComicLayout.unknown);
        var finished = false;
        final observed = failDescriptor
            ? expectDoneFailure(
                probe,
                isA<ComicLayoutProbeFailure>().having(
                  (e) => e.failures,
                  'late descriptor failure',
                  everyElement((
                    stage: 'descriptor creation',
                    error: failure,
                    stack: stack,
                  )),
                ),
              )
            : probe.done;
        unawaited(observed.then((_) => finished = true));
        await pumpEventQueue();
        expect(finished, isFalse);
        for (final completion in pending) {
          if (failDescriptor) {
            completion.completeError(failure, stack);
          } else {
            final descriptor = _Descriptor();
            descriptors.add(descriptor);
            completion.complete(descriptor);
          }
        }
        await observed;
        expect(buffers.every((buffer) => buffer.debugDisposed), isTrue);
        expect(
          descriptors.every((descriptor) => descriptor.disposals == 1),
          isTrue,
        );
      },
    );
  }

  test(
    'descriptor disposal failure still releases buffers and subscriptions',
    () async {
      final buffers = <ui.ImmutableBuffer>[];
      final descriptors = <_Descriptor>[];
      var cancellations = 0;
      final failure = StateError('descriptor disposal');
      final stack = StackTrace.fromString('descriptor disposal stack');
      loader = (_, _, _, _) {
        late StreamController<ImageDownloadProgress> stream;
        stream = StreamController<ImageDownloadProgress>(
          onListen: () => stream.add(event(page)),
          onCancel: () => cancellations++,
        );
        return stream.stream;
      };
      final probe = createProbe(
        createBuffer: (data) async {
          final buffer = await ui.ImmutableBuffer.fromUint8List(data);
          buffers.add(buffer);
          return buffer;
        },
        createDescriptor: (_) async {
          final descriptor = _Descriptor(
            onDispose: () => Error.throwWithStackTrace(failure, stack),
          );
          descriptors.add(descriptor);
          return descriptor;
        },
      );
      final matcher = isA<ComicLayoutProbeFailure>().having(
        (e) => e.failures,
        'descriptor disposal errors',
        everyElement((
          stage: 'descriptor disposal',
          error: failure,
          stack: stack,
        )),
      );
      final done = expectDoneFailure(probe, matcher);
      await expectLater(detect(probe), throwsA(matcher));
      await done;
      expect(buffers.every((buffer) => buffer.debugDisposed), isTrue);
      expect(
        descriptors.every((descriptor) => descriptor.disposals == 1),
        isTrue,
      );
      expect(cancellations, 6);
    },
  );

  test(
    'cancelling a probe preserves another real shared-stream subscriber',
    () async {
      final requests = SharedImageRequests<ImageDownloadProgress>();
      final sources = <String, StreamController<ImageDownloadProgress>>{};
      final cancellations = <String>[];
      loader = (url, _, _, _) => requests.open((_) {
        return (sources[url] = StreamController<ImageDownloadProgress>(
          onCancel: () => cancellations.add(url),
        )).stream;
      }, key: url);
      final received = <ImageDownloadProgress>[];
      final other = loader(
        images[1],
        'source',
        'comic',
        'chapter',
      ).listen(received.add);
      final probe = createProbe();
      final result = detect(probe);
      await pumpEventQueue();
      probe.cancel();
      await result;
      await probe.done;
      expect(cancellations, isNot(contains(images[1])));
      final sharedEvent = event(page);
      sources[images[1]]!.add(sharedEvent);
      await pumpEventQueue();
      expect(received, [sharedEvent]);
      await other.cancel();
      expect(cancellations.where((url) => url == images[1]), hasLength(1));
      await requests.cancelAll();
      for (final stream in sources.values) {
        await stream.close();
      }
    },
  );
}

class _PendingFile extends Fake implements File {
  _PendingFile(this.path, this.size, this.reads);
  @override
  final String path;
  final int size;
  final List<Completer<Uint8List>> reads;
  @override
  Future<int> length() async => size;
  @override
  Future<Uint8List> readAsBytes() {
    final read = Completer<Uint8List>();
    reads.add(read);
    return read.future;
  }
}

class _Descriptor extends Fake implements ui.ImageDescriptor {
  _Descriptor({this.onDispose});
  final void Function()? onDispose;
  var disposals = 0;
  @override
  int get width => 20;
  @override
  int get height => 30;
  @override
  void dispose() {
    disposals++;
    onDispose?.call();
  }
}
