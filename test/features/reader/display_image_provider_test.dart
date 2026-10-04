import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/display_image_provider.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/foundation/image_provider/base_image_provider.dart';
import 'package:venera_next/foundation/image_provider/reader_image.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/image_stream.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==',
);

class _Provider extends ReaderImageProvider {
  _Provider(String key, this.read, {this.decoder})
    : super(key, null, 'comic', 'chapter', 1);
  final Future<Uint8List> Function() read;
  final ImageDecoderCallback? decoder;
  int loads = 0;
  final cancellationSignals = <Future<void>>[];

  @override
  Future<Uint8List> load(chunkEvents, checkStop) {
    loads++;
    cancellationSignals.add(BaseImageProvider.cancelSignalOf(checkStop));
    return read();
  }

  @override
  ImageStreamCompleter loadImage(
    ReaderImageProvider key,
    ImageDecoderCallback decode,
  ) => super.loadImage(key, decoder ?? decode);
}

class _Frame implements ui.FrameInfo {
  _Frame(this.image);
  @override
  final ui.Image image;
  @override
  Duration get duration => Duration.zero;
}

class _Codec implements ui.Codec {
  _Codec(this.frame);
  final Future<ui.FrameInfo> frame;
  int reads = 0;
  int disposals = 0;
  @override
  int get frameCount => 1;
  @override
  int get repetitionCount => 0;
  @override
  Future<ui.FrameInfo> getNextFrame() {
    reads++;
    return frame;
  }

  @override
  void dispose() => disposals++;
}

Future<void> _frame() async {
  SchedulerBinding.instance.handleBeginFrame(Duration.zero);
  SchedulerBinding.instance.handleDrawFrame();
  await pumpEventQueue();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var nextKey = 0;
  final works = <ImageWork>[];
  final detach = <void Function()>[];
  final finishReads = <void Function()>[];

  ImageWork work() {
    final value = ImageWork();
    works.add(value);
    return value;
  }

  _Provider provider(
    Future<Uint8List> Function() read, {
    ImageDecoderCallback? decoder,
  }) => _Provider('visible-${nextKey++}', read, decoder: decoder);

  Completer<Uint8List> pendingRead() {
    final gate = Completer<Uint8List>();
    finishReads.add(() {
      if (!gate.isCompleted) gate.complete(_png);
    });
    return gate;
  }

  ImageStreamListener listen(
    ImageStream stream, {
    void Function(ImageInfo)? onImage,
    void Function(Object, StackTrace?)? onError,
  }) {
    final listener = ImageStreamListener((info, _) {
      try {
        onImage?.call(info);
      } finally {
        info.dispose();
      }
    }, onError: onError ?? (Object error, StackTrace? stack) {});
    stream.addListener(listener);
    detach.add(() => stream.removeListener(listener));
    return listener;
  }

  setUp(() {
    final muted = Log.isMuted;
    Log.isMuted = true;
    addTearDown(() => Log.isMuted = muted);
  });

  tearDown(() async {
    for (final finish in finishReads) {
      finish();
    }
    finishReads.clear();
    for (final remove in detach) {
      remove();
    }
    detach.clear();
    final closing = [for (final owner in works) owner.dispose()];
    await _frame();
    await Future.wait(closing);
    works.clear();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await _frame();
    final release = await BaseImageProvider.prepareForExit();
    release();
  });

  test(
    'two visible listeners stay mounted while preparation joins and resumes',
    () async {
      final owner = work();
      final read = pendingRead();
      var first = true;
      final source = provider(() {
        if (first) {
          first = false;
          return read.future;
        }
        return Future.value(_png);
      });
      final visible = ReaderDisplayImageProvider(source, owner);
      final sizeStream = visible.resolve(ImageConfiguration.empty);
      final paintStream = visible.resolve(
        const ImageConfiguration(devicePixelRatio: 2),
      );
      expect(sizeStream.completer, same(paintStream.completer));
      var frames = 0;
      final errors = <Object>[];
      listen(
        sizeStream,
        onImage: (_) => frames++,
        onError: (e, _) => errors.add(e),
      );
      listen(
        paintStream,
        onImage: (_) => frames++,
        onError: (e, _) => errors.add(e),
      );
      expect(source.loads, 1);
      expect(PaintingBinding.instance.imageCache.containsKey(visible), isFalse);
      var prepared = false;
      final preparing = owner.prepareForExit().then((release) {
        prepared = true;
        return release;
      });
      await _frame();
      expect(prepared, isFalse);
      expect(frames, 0);
      read.complete(_png);
      final release = await preparing;
      expect(source.loads, 1);
      expect(frames, 0);
      release();
      await pumpEventQueue();
      await _frame();
      expect(source.loads, 2);
      expect(frames, 2);
      expect(errors, isEmpty);
    },
  );

  test(
    'one reader hands shared loading to another without cancelling its consumer',
    () async {
      final first = work();
      final second = work();
      final read = pendingRead();
      final source = provider(() => read.future);
      final a = ReaderDisplayImageProvider(
        source,
        first,
      ).resolve(ImageConfiguration.empty);
      final b = ReaderDisplayImageProvider(
        source,
        second,
      ).resolve(ImageConfiguration.empty);
      var received = false;
      listen(a);
      listen(b, onImage: (_) => received = true);
      final releaseFirst = await first.prepareForExit();
      expect(source.loads, 1);
      expect(read.isCompleted, isFalse);
      read.complete(_png);
      await pumpEventQueue();
      await _frame();
      expect(received, isTrue);
      releaseFirst();
      await pumpEventQueue();
      expect(source.loads, 1);
    },
  );

  test(
    'last visible listener with keepAlive releases work and can later resume',
    () async {
      final owner = work();
      final read = pendingRead();
      var first = true;
      final source = provider(() {
        if (first) {
          first = false;
          return read.future;
        }
        return Future.value(_png);
      });
      final visible = ReaderDisplayImageProvider(source, owner);
      final stream = visible.resolve(ImageConfiguration.empty);
      final handle = stream.completer!.keepAlive();
      addTearDown(handle.dispose);
      final firstListener = listen(stream);
      stream.removeListener(firstListener);
      var done = false;
      final preparing = owner.prepareForExit().then((release) {
        done = true;
        return release;
      });
      await _frame();
      expect(done, isFalse);
      read.complete(_png);
      (await preparing)();
      expect(source.loads, 1);
      var frames = 0;
      listen(stream, onImage: (_) => frames++);
      await pumpEventQueue();
      await _frame();
      expect(source.loads, 2);
      expect(frames, 1);
    },
  );

  test(
    'native frame finishes after cancellation without reaching visible consumers',
    () async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(
        recorder,
      ).drawColor(const ui.Color(0xff336699), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(1, 1);
      picture.dispose();
      final native = Completer<ui.FrameInfo>();
      finishReads.add(() {
        if (!native.isCompleted) native.complete(_Frame(image));
      });
      final codec = _Codec(native.future);
      final source = provider(
        () async => _png,
        decoder: (buffer, {getTargetSize}) async {
          buffer.dispose();
          return codec;
        },
      );
      final owner = work();
      final stream = ReaderDisplayImageProvider(
        source,
        owner,
      ).resolve(ImageConfiguration.empty);
      var frames = 0;
      listen(stream, onImage: (_) => frames++);
      await pumpEventQueue();
      expect(codec.reads, 1);
      var done = false;
      final preparing = owner.prepareForExit().then((release) {
        done = true;
        return release;
      });
      await _frame();
      expect(done, isFalse);
      expect(codec.disposals, 0);
      native.complete(_Frame(image));
      await preparing;
      expect(codec.disposals, 1);
      expect(image.debugDisposed, isTrue);
      expect(frames, 0);
    },
  );

  test(
    'active cleanup error reaches UI and owner only once with original stack',
    () async {
      final owner = work();
      final read = pendingRead();
      final source = provider(() => read.future);
      final stack = StackTrace.fromString('visible original cleanup');
      final error = ImageStreamCleanupFailure([
        (stage: 'subscription', error: StateError('cleanup'), stack: stack),
      ]);
      final stream = ReaderDisplayImageProvider(
        source,
        owner,
      ).resolve(ImageConfiguration.empty);
      final observed = Completer<void>();
      listen(
        stream,
        onError: (actual, actualStack) {
          expect(actual, same(error));
          expect(actualStack, same(stack));
          observed.complete();
        },
      );
      read.completeError(error, stack);
      await observed.future;
      await _frame();
      await expectLater(
        owner.prepareForExit(),
        throwsA(
          isA<ImageWorkFailure>().having(
            (e) => e.failures,
            'one original error',
            [(error: error, stack: stack)],
          ),
        ),
      );
    },
  );

  test('ordinary load failure gets a fresh relay on explicit retry', () async {
    final owner = work();
    var first = true;
    final source = provider(() {
      if (first) {
        first = false;
        return Future.error(StateError('Invalid Status Code: 404'));
      }
      return Future.value(_png);
    });
    final visible = ReaderDisplayImageProvider(source, owner);
    final stream = visible.resolve(ImageConfiguration.empty);
    final failed = Completer<void>();
    listen(stream, onError: (_, _) => failed.complete());
    await failed.future;
    await _frame();
    final next = visible.resolve(ImageConfiguration.empty);
    expect(next.completer, isNot(same(stream.completer)));
    var frames = 0;
    listen(next, onImage: (_) => frames++);
    await pumpEventQueue();
    await _frame();
    expect(source.loads, 2);
    expect(frames, 1);
    final preparing = owner.prepareForExit();
    await _frame();
    (await preparing)();
  });

  test(
    'visible listeners added during an existing hold start only on final resume',
    () async {
      final owner = work();
      final releaseFirst = owner.holdForExit();
      final releaseSecond = owner.holdForExit();
      final source = provider(() async => _png);
      final visible = ReaderDisplayImageProvider(source, owner);
      final stream = visible.resolve(ImageConfiguration.empty);
      var frames = 0;
      listen(stream, onImage: (_) => frames++);
      listen(stream, onImage: (_) => frames++);
      await _frame();
      expect(source.loads, 0);
      releaseFirst();
      expect(source.loads, 0);
      releaseSecond();
      await pumpEventQueue();
      await _frame();
      expect(source.loads, 1);
      expect(frames, 2);
    },
  );

  test(
    'rejoining visible listener waits for the retired attempt cleanup',
    () async {
      final owner = work();
      final original = pendingRead();
      final replacement = pendingRead();
      var calls = 0;
      final source = provider(
        () => calls++ == 0 ? original.future : replacement.future,
      );
      final stream = ReaderDisplayImageProvider(
        source,
        owner,
      ).resolve(ImageConfiguration.empty);
      final handle = stream.completer!.keepAlive();
      addTearDown(handle.dispose);
      final first = listen(stream);
      stream.removeListener(first);
      detach.removeLast();
      listen(stream);
      final release = owner.holdForExit();
      release();
      await _frame();
      expect(source.loads, 1);
      original.complete(_png);
      await pumpEventQueue();
      await _frame();
      expect(source.loads, 2);
      replacement.complete(_png);
      await pumpEventQueue();
      await _frame();
      expect(source.loads, 2);
    },
  );

  test(
    'each final listener removal cancels its attempt while relay stays alive',
    () async {
      final owner = work();
      final firstRead = pendingRead();
      final secondRead = pendingRead();
      var calls = 0;
      final source = provider(
        () => calls++ == 0 ? firstRead.future : secondRead.future,
      );
      final stream = ReaderDisplayImageProvider(
        source,
        owner,
      ).resolve(ImageConfiguration.empty);
      final handle = stream.completer!.keepAlive();
      addTearDown(handle.dispose);
      final first = listen(stream);
      stream.removeListener(first);
      detach.removeLast();
      await _frame();
      firstRead.complete(_png);
      await pumpEventQueue();
      final second = listen(stream);
      expect(source.loads, 2);
      var cancelled = false;
      unawaited(source.cancellationSignals.last.then((_) => cancelled = true));
      stream.removeListener(second);
      detach.removeLast();
      await _frame();
      expect(cancelled, true);
    },
  );

  test(
    'old relay does not evict a replacement pending stream with the same key',
    () async {
      final oldOwner = work();
      final nextOwner = work();
      final oldRead = pendingRead();
      final nextRead = pendingRead();
      var calls = 0;
      final source = provider(
        () => calls++ == 0 ? oldRead.future : nextRead.future,
      );
      final cache = PaintingBinding.instance.imageCache;
      final oldStream = ReaderDisplayImageProvider(
        source,
        oldOwner,
      ).resolve(ImageConfiguration.empty);
      listen(oldStream);
      expect(cache.evict(source), true);
      final nextStream = ReaderDisplayImageProvider(
        source,
        nextOwner,
      ).resolve(ImageConfiguration.empty);
      var nextFrames = 0;
      listen(nextStream, onImage: (_) => nextFrames++);
      expect(source.loads, 2);
      expect(cache.statusForKey(source).pending, true);
      var prepared = false;
      final preparing = oldOwner.prepareForExit().then((release) {
        prepared = true;
        return release;
      });
      await _frame();
      expect(prepared, false);
      expect(cache.statusForKey(source).pending, true);
      oldRead.complete(_png);
      await preparing;
      expect(cache.statusForKey(source).pending, true);
      expect(nextFrames, 0);
      nextRead.complete(_png);
      await pumpEventQueue();
      await _frame();
      expect(nextFrames, 1);
      expect(cache.statusForKey(source).keepAlive, true);
      expect(source.loads, 2);
    },
  );

  for (final beforeFrame in [false, true]) {
    test(
      'cancelled visible failure retains stack without replay; beforeFrame=$beforeFrame',
      () async {
        final owner = work();
        final read = pendingRead();
        var first = true;
        final source = provider(() {
          if (first) {
            first = false;
            return read.future;
          }
          return Future.value(_png);
        });
        final stream = ReaderDisplayImageProvider(
          source,
          owner,
        ).resolve(ImageConfiguration.empty);
        final visibleErrors = <Object>[];
        listen(stream, onError: (error, _) => visibleErrors.add(error));
        final error = StateError('Invalid Status Code: 404 after release');
        final stack = StackTrace.fromString('late visible original stack');
        final preparing = owner.prepareForExit();
        final checked = expectLater(
          preparing,
          throwsA(
            isA<ImageWorkFailure>().having(
              (failure) => failure.failures,
              'one original late failure',
              [(error: error, stack: stack)],
            ),
          ),
        );
        if (!beforeFrame) await _frame();
        read.completeError(error, stack);
        await pumpEventQueue();
        await _frame();
        await checked;
        expect(visibleErrors, isEmpty);
        await pumpEventQueue();
        await _frame();
        final nextPreparation = owner.prepareForExit();
        await _frame();
        final release = await nextPreparation;
        final globalRelease = await BaseImageProvider.prepareForExit();
        globalRelease();
        release();
      },
    );
  }

  test(
    'onError can remove its listener, release a hold and resolve a retry',
    () async {
      final owner = work();
      final read = pendingRead();
      var first = true;
      final source = provider(() {
        if (first) {
          first = false;
          return read.future;
        }
        return Future.value(_png);
      });
      final visible = ReaderDisplayImageProvider(source, owner);
      final stream = visible.resolve(ImageConfiguration.empty);
      final stack = StackTrace.fromString('reentrant cleanup stack');
      final error = ImageStreamCleanupFailure([
        (stage: 'subscription', error: StateError('cleanup'), stack: stack),
      ]);
      var attached = true;
      var frames = 0;
      final observed = Completer<void>();
      late final ImageStreamListener listener;
      void remove() {
        if (!attached) return;
        attached = false;
        stream.removeListener(listener);
      }

      listener = ImageStreamListener(
        (info, _) => info.dispose(),
        onError: (Object actual, StackTrace? actualStack) {
          expect(actual, same(error));
          expect(actualStack, same(stack));
          final release = owner.holdForExit();
          remove();
          release();
          final retry = visible.resolve(ImageConfiguration.empty);
          expect(retry.completer, isNot(same(stream.completer)));
          listen(retry, onImage: (_) => frames++);
          observed.complete();
        },
      );
      stream.addListener(listener);
      detach.add(remove);
      read.completeError(error, stack);
      await observed.future;
      await pumpEventQueue();
      await _frame();
      expect(source.loads, 2);
      expect(frames, 1);
      final preparation = owner.prepareForExit();
      final checked = expectLater(
        preparation,
        throwsA(
          isA<ImageWorkFailure>().having(
            (failure) => failure.failures,
            'one cleanup failure after reentrant retry',
            [(error: error, stack: stack)],
          ),
        ),
      );
      await _frame();
      await checked;
    },
  );
}
