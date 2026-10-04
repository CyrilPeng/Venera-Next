import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/image_provider/base_image_provider.dart';
import 'package:venera_next/foundation/image_provider/image_provider_lifecycle.dart';
import 'package:venera_next/foundation/log.dart';

class _Provider extends BaseImageProvider<_Provider> {
  _Provider(this.read, {String? cacheKey}) : _cacheKey = cacheKey;

  final Future<Uint8List> Function() read;
  final String? _cacheKey;
  int loads = 0;

  @override
  String get key => _cacheKey ?? 'release-${identityHashCode(this)}';

  @override
  Future<_Provider> obtainKey(ImageConfiguration configuration) async => this;

  @override
  Future<Uint8List> load(chunkEvents, checkStop) {
    loads++;
    return read();
  }
}

class _Frame implements ui.FrameInfo {
  _Frame(this.image);

  @override
  final ui.Image image;

  @override
  Duration get duration => const Duration(milliseconds: 10);
}

class _Codec implements ui.Codec {
  _Codec(
    this.frame, {
    this.disposeFailure,
    this.disposeStack,
    this.frameCount = 1,
  });

  final Future<ui.FrameInfo> Function() frame;
  final Object? disposeFailure;
  final StackTrace? disposeStack;
  int reads = 0;
  int disposals = 0;

  @override
  final int frameCount;

  @override
  int get repetitionCount => 0;

  @override
  Future<ui.FrameInfo> getNextFrame() {
    reads++;
    return frame();
  }

  @override
  void dispose() {
    disposals++;
    if (disposeFailure != null) {
      Error.throwWithStackTrace(
        disposeFailure!,
        disposeStack ?? StackTrace.current,
      );
    }
  }
}

ImageStream _stream(_Provider provider, ImageDecoderCallback decode) =>
    ImageStream()..setCompleter(provider.loadImage(provider, decode));

ImageStreamListener _listener() => ImageStreamListener(
  (image, _) => image.dispose(),
  onError: (Object error, StackTrace? stack) {},
);

Future<ui.Image> _image() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xff00ff00), ui.BlendMode.src);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(1, 1);
  } finally {
    picture.dispose();
  }
}

Iterable<Object> _causes(Object error) sync* {
  if (error is ImageProviderPreparationFailure) {
    for (final failure in error.failures) {
      yield* _causes(failure.error);
    }
  } else {
    yield error;
  }
}

Matcher _containsFailure(Object failure) =>
    isA<ImageProviderPreparationFailure>().having(
      (error) => _causes(error),
      'underlying failures',
      contains(same(failure)),
    );

Future<void> _expectNoBufferedFailure() async {
  final release = await BaseImageProvider.prepareForExit();
  release();
}

Future<void> _frame() async {
  SchedulerBinding.instance.handleBeginFrame(Duration.zero);
  SchedulerBinding.instance.handleDrawFrame();
  await pumpEventQueue();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final muted = Log.isMuted;
    Log.isMuted = true;
    addTearDown(() => Log.isMuted = muted);
  });

  tearDown(() async {
    await pumpEventQueue();
    expect(BaseImageProvider.debugActiveLoadCount, 0);
  });

  test(
    'release during an admission hold finishes without starting a read',
    () async {
      final release = await BaseImageProvider.prepareForExit();
      addTearDown(release);
      final provider = _Provider(() async => Uint8List(1));
      final stream = _stream(provider, (buffer, {getTargetSize}) async {
        buffer.dispose();
        throw StateError('held stream must not decode');
      });
      final listener = _listener();
      stream.addListener(listener);
      stream.removeListener(listener);
      await BaseImageProvider.waitForReleasedStream(stream);
      expect(provider.loads, 0);
      release();
      await pumpEventQueue();
      expect(provider.loads, 0);
      await _expectNoBufferedFailure();
    },
  );

  test(
    'idle codec cleanup failure closes and is consumed by its local owner',
    () async {
      final failure = StateError('idle native codec cleanup failed');
      final codec = _Codec(
        () => throw StateError('stream has no frame listener'),
        disposeFailure: failure,
      );
      final provider = _Provider(() async => Uint8List(1));
      final stream = _stream(provider, (buffer, {getTargetSize}) async {
        buffer.dispose();
        return codec;
      });
      final handle = stream.completer!.keepAlive();
      final listener = _listener();
      stream.addListener(listener);
      stream.removeListener(listener);
      await pumpEventQueue();
      expect(codec.reads, 0);
      expect(codec.disposals, 0);
      handle.dispose();
      await expectLater(
        BaseImageProvider.waitForReleasedStream(stream),
        throwsA(_containsFailure(failure)),
      );
      expect(codec.disposals, 1);
      await _expectNoBufferedFailure();
    },
  );

  test(
    'released stream joins its original read without starting decode',
    () async {
      final read = Completer<Uint8List>();
      final provider = _Provider(() => read.future);
      var decodes = 0;
      final stream = _stream(provider, (buffer, {getTargetSize}) async {
        decodes++;
        buffer.dispose();
        throw StateError('cancelled read must not decode');
      });
      final listener = _listener();
      stream.addListener(listener);
      stream.removeListener(listener);
      var joined = false;
      final joining = BaseImageProvider.waitForReleasedStream(stream).then((_) {
        joined = true;
      });
      final otherJoining = BaseImageProvider.waitForReleasedStream(stream);
      await pumpEventQueue();
      expect(joined, isFalse);
      expect(BaseImageProvider.debugActiveLoadCount, 1);
      read.complete(Uint8List(1));
      await Future.wait([joining, otherJoining]);
      expect(provider.loads, 1);
      expect(decodes, 0);
      await _expectNoBufferedFailure();
    },
  );

  test(
    'released stream joins decoder completion and disposes its late codec',
    () async {
      final decoding = Completer<ui.Codec>();
      final codec = _Codec(() => throw StateError('must not request a frame'));
      final provider = _Provider(() async => Uint8List(1));
      var started = false;
      final stream = _stream(provider, (buffer, {getTargetSize}) {
        buffer.dispose();
        started = true;
        return decoding.future;
      });
      final listener = _listener();
      stream.addListener(listener);
      await pumpEventQueue();
      expect(started, isTrue);
      stream.removeListener(listener);
      var joined = false;
      final joining = BaseImageProvider.waitForReleasedStream(stream).then((_) {
        joined = true;
      });
      await pumpEventQueue();
      expect(joined, isFalse);
      expect(codec.disposals, 0);
      decoding.complete(codec);
      await joining;
      expect(codec.disposals, 1);
      expect(codec.reads, 0);
      await _expectNoBufferedFailure();
    },
  );

  test(
    'released stream joins native frame and disposes both image and codec',
    () async {
      final native = Completer<ui.FrameInfo>();
      final image = await _image();
      final codec = _Codec(() => native.future);
      final provider = _Provider(() async => Uint8List(1));
      final stream = _stream(provider, (buffer, {getTargetSize}) async {
        buffer.dispose();
        return codec;
      });
      final listener = _listener();
      stream.addListener(listener);
      await pumpEventQueue();
      expect(codec.reads, 1);
      stream.removeListener(listener);
      var joined = false;
      final joining = BaseImageProvider.waitForReleasedStream(stream).then((_) {
        joined = true;
      });
      await pumpEventQueue();
      expect(joined, isFalse);
      expect(codec.disposals, 0);
      native.complete(_Frame(image));
      await joining;
      expect(image.debugDisposed, isTrue);
      expect(image.debugGetOpenHandleStackTraces(), isEmpty);
      expect(codec.disposals, 1);
      await _expectNoBufferedFailure();
    },
  );

  for (final keepAlive in [false, true]) {
    test(
      'another ${keepAlive ? 'cache handle' : 'listener'} retains ownership',
      () async {
        final read = Completer<Uint8List>();
        final provider = _Provider(() => read.future);
        final stream = _stream(provider, (buffer, {getTargetSize}) async {
          buffer.dispose();
          throw StateError('cancelled read must not decode');
        });
        final first = _listener();
        final other = _listener();
        final handle = keepAlive ? stream.completer!.keepAlive() : null;
        stream.addListener(first);
        if (!keepAlive) stream.addListener(other);
        stream.removeListener(first);
        var released = false;
        final releasing = BaseImageProvider.waitForReleasedStream(stream).then((
          _,
        ) {
          released = true;
        });
        await pumpEventQueue();
        expect(released, !keepAlive);
        if (keepAlive) await _frame();
        await releasing;
        expect(read.isCompleted, isFalse);
        expect(BaseImageProvider.debugActiveLoadCount, 1);
        if (keepAlive) {
          handle!.dispose();
        } else {
          stream.removeListener(other);
        }
        var joined = false;
        final joining = BaseImageProvider.waitForReleasedStream(stream).then((
          _,
        ) {
          joined = true;
        });
        await pumpEventQueue();
        expect(joined, isFalse);
        read.complete(Uint8List(1));
        await joining;
        expect(provider.loads, 1);
        await _expectNoBufferedFailure();
      },
    );
  }

  test(
    'local read failure is delivered once and not replayed globally',
    () async {
      final read = Completer<Uint8List>();
      final failure = StateError('original read failed after cancellation');
      final provider = _Provider(() => read.future);
      final stream = _stream(provider, (buffer, {getTargetSize}) async {
        buffer.dispose();
        throw StateError('must not decode');
      });
      final listener = _listener();
      stream.addListener(listener);
      stream.removeListener(listener);
      final joining = BaseImageProvider.waitForReleasedStream(stream);
      final observed = expectLater(joining, throwsA(_containsFailure(failure)));
      read.completeError(failure);
      await observed;
      await expectLater(
        BaseImageProvider.waitForReleasedStream(stream),
        throwsA(_containsFailure(failure)),
      );
      await _expectNoBufferedFailure();
    },
  );

  for (final fails in [false, true]) {
    test(
      'real image cache retires its handle before joining read cleanup; fails=$fails',
      () async {
        final read = Completer<Uint8List>();
        final provider = _Provider(() => read.future);
        final cache = PaintingBinding.instance.imageCache;
        final stream = provider.resolve(ImageConfiguration.empty);
        final listener = _listener();
        stream.addListener(listener);
        await pumpEventQueue();
        expect(provider.loads, 1);
        expect(cache.statusForKey(provider).pending, isTrue);
        expect(cache.statusForKey(provider).live, isTrue);

        // The pending listener is released now; ImageCache's live keepAlive is
        // only retired by the post-frame callback triggered by the last listener.
        cache.evict(provider, includeLive: false);
        stream.removeListener(listener);
        expect(cache.statusForKey(provider).pending, isFalse);
        expect(cache.statusForKey(provider).live, isFalse);
        var joined = false;
        final joining = BaseImageProvider.waitForReleasedStream(stream)
            .whenComplete(() {
              joined = true;
            });
        final failure = StateError('cached image read failed after release');
        final observed = fails
            ? expectLater(joining, throwsA(_containsFailure(failure)))
            : expectLater(joining, completes);
        await pumpEventQueue();
        expect(joined, isFalse);
        await _frame();
        expect(joined, isFalse);
        expect(BaseImageProvider.debugActiveLoadCount, 1);
        if (fails) {
          read.completeError(failure);
        } else {
          read.complete(Uint8List(1));
        }
        await observed;
        expect(joined, isTrue);
        expect(provider.loads, 1);
        expect(cache.containsKey(provider), isFalse);
        await _expectNoBufferedFailure();
      },
    );
  }

  test(
    'an active failed pending image is evicted so a later resolve retries',
    () async {
      final firstRead = Completer<Uint8List>();
      final cause = StateError('first stream cleanup failed');
      final failure = ImageProviderPreparationFailure([
        (error: cause, stack: StackTrace.current),
      ]);
      late final _Provider provider;
      provider = _Provider(
        () =>
            provider.loads == 1 ? firstRead.future : Future.value(Uint8List(1)),
      );
      final cache = PaintingBinding.instance.imageCache;
      final nativeImage = await _image();
      ImageStream resolve() => ImageStream()
        ..setCompleter(
          cache.putIfAbsent(
            provider,
            () => provider.loadImage(provider, (buffer, {getTargetSize}) async {
              buffer.dispose();
              return _Codec(() async => _Frame(nativeImage));
            }),
          )!,
        );
      final errors = <Object>[];
      final first = resolve();
      final firstListener = ImageStreamListener(
        (image, _) => image.dispose(),
        onError: (Object error, StackTrace? _) => errors.add(error),
      );
      first.addListener(firstListener);
      expect(cache.statusForKey(provider).pending, isTrue);
      firstRead.completeError(failure);
      await pumpEventQueue();
      expect(errors, [same(failure)]);
      expect(cache.statusForKey(provider).pending, isFalse);
      expect(cache.statusForKey(provider).live, isFalse);
      expect(provider.loads, 1);
      first.removeListener(firstListener);
      await _frame();
      await expectLater(
        BaseImageProvider.waitForReleasedStream(first),
        throwsA(_containsFailure(cause)),
      );
      final second = resolve();
      expect(second.completer, isNot(same(first.completer)));
      await pumpEventQueue();
      expect(provider.loads, 2);
      expect(cache.statusForKey(provider).keepAlive, isTrue);
      cache.evict(provider, includeLive: true);
      await _frame();
      await BaseImageProvider.waitForReleasedStream(second);
      await _expectNoBufferedFailure();
    },
  );

  for (final cacheCompleted in [false, true]) {
    test(
      'retired read failure preserves a same-key ${cacheCompleted ? 'completed cache' : 'pending load'}',
      () async {
        final oldRead = Completer<Uint8List>();
        final newRead = Completer<Uint8List>();
        final failure = StateError('retired read failed after cancellation');
        final cacheKey = 'replacement-$cacheCompleted';
        final oldProvider = _Provider(() => oldRead.future, cacheKey: cacheKey);
        final newProvider = _Provider(() => newRead.future, cacheKey: cacheKey);
        final cache = PaintingBinding.instance.imageCache;
        final nativeImage = cacheCompleted ? await _image() : null;
        ImageStream cachedStream(
          _Provider provider,
          ImageDecoderCallback decode,
        ) => ImageStream()
          ..setCompleter(
            cache.putIfAbsent(
              provider,
              () => provider.loadImage(provider, decode),
            )!,
          );
        final oldStream = cachedStream(oldProvider, (buffer, {getTargetSize}) {
          buffer.dispose();
          throw StateError('retired read must not decode');
        });
        final oldListener = _listener();
        oldStream.addListener(oldListener);
        expect(cache.evict(oldProvider, includeLive: true), isTrue);
        final newStream = cachedStream(newProvider, (
          buffer, {
          getTargetSize,
        }) async {
          buffer.dispose();
          if (nativeImage == null) {
            throw StateError('pending replacement must not decode');
          }
          return _Codec(() async => _Frame(nativeImage));
        });
        final newListener = _listener();
        newStream.addListener(newListener);
        var newListening = true;
        try {
          if (cacheCompleted) {
            newRead.complete(Uint8List(1));
            await pumpEventQueue();
            newStream.removeListener(newListener);
            newListening = false;
            await _frame();
          }
          expect(cache.statusForKey(newProvider).pending, !cacheCompleted);
          expect(cache.statusForKey(newProvider).keepAlive, cacheCompleted);
          expect(cache.statusForKey(newProvider).live, !cacheCompleted);
          oldStream.removeListener(oldListener);
          final observed = expectLater(
            BaseImageProvider.waitForReleasedStream(oldStream),
            throwsA(_containsFailure(failure)),
          );
          await _frame();
          oldRead.completeError(failure);
          await observed;
          expect(cache.statusForKey(newProvider).pending, !cacheCompleted);
          expect(cache.statusForKey(newProvider).keepAlive, cacheCompleted);
          expect(cache.statusForKey(newProvider).live, !cacheCompleted);
          expect(newProvider.loads, 1);
        } finally {
          cache.evict(newProvider, includeLive: true);
          if (newListening) newStream.removeListener(newListener);
          await _frame();
          if (!newRead.isCompleted) newRead.complete(Uint8List(1));
          await BaseImageProvider.waitForReleasedStream(newStream);
          await _expectNoBufferedFailure();
        }
      },
    );
  }

  for (final globalTiming in ['none', 'active', 'retired']) {
    test(
      'native cleanup failure reaches local owner and $globalTiming global preparation',
      () async {
        final native = Completer<ui.FrameInfo>();
        final image = await _image();
        final failure = StateError('native codec cleanup failed');
        final codec = _Codec(() => native.future, disposeFailure: failure);
        final provider = _Provider(() async => Uint8List(1));
        final stream = _stream(provider, (buffer, {getTargetSize}) async {
          buffer.dispose();
          return codec;
        });
        final listener = _listener();
        stream.addListener(listener);
        await pumpEventQueue();
        expect(codec.reads, 1);
        stream.removeListener(listener);
        Future<void>? globalObserved;
        if (globalTiming == 'active') {
          globalObserved = expectLater(
            BaseImageProvider.prepareForExit(),
            throwsA(_containsFailure(failure)),
          );
        }
        Future<void>? localObserved;
        if (globalTiming != 'retired') {
          localObserved = expectLater(
            BaseImageProvider.waitForReleasedStream(stream),
            throwsA(_containsFailure(failure)),
          );
        }
        native.complete(_Frame(image));
        if (globalTiming == 'retired') {
          await pumpEventQueue();
          expect(BaseImageProvider.debugActiveLoadCount, 0);
          globalObserved = expectLater(
            BaseImageProvider.prepareForExit(),
            throwsA(_containsFailure(failure)),
          );
          localObserved = expectLater(
            BaseImageProvider.waitForReleasedStream(stream),
            throwsA(_containsFailure(failure)),
          );
        }
        await localObserved;
        await globalObserved;
        expect(codec.disposals, 1);
        expect(image.debugDisposed, isTrue);
        expect(image.debugGetOpenHandleStackTraces(), isEmpty);
        await _expectNoBufferedFailure();
      },
    );
  }

  for (final globalHold in [false, true]) {
    test(
      'completed cache joins only its in-flight native frame; global hold=$globalHold',
      () async {
        final native = Completer<ui.FrameInfo>();
        final first = await _image();
        final second = await _image();
        late final _Codec codec;
        codec = _Codec(
          () => codec.reads == 1 ? Future.value(_Frame(first)) : native.future,
          frameCount: 2,
        );
        final provider = _Provider(() async => Uint8List(1));
        final cache = PaintingBinding.instance.imageCache;
        final stream = ImageStream()
          ..setCompleter(
            cache.putIfAbsent(
              provider,
              () =>
                  provider.loadImage(provider, (buffer, {getTargetSize}) async {
                    buffer.dispose();
                    return codec;
                  }),
            )!,
          );
        var visible = 0;
        final listener = ImageStreamListener((info, _) {
          visible++;
          info.dispose();
        }, onError: (Object _, StackTrace? _) {});
        stream.addListener(listener);
        VoidCallback? releaseGlobal;
        try {
          await pumpEventQueue();
          await _frame();
          expect(visible, 1);
          expect(codec.reads, 2);
          expect(cache.statusForKey(provider).keepAlive, isTrue);
          stream.removeListener(listener);
          var joined = false;
          final joining = BaseImageProvider.waitForReleasedStream(
            stream,
            waitForCurrentFrame: true,
          ).then((_) => joined = true);
          final preparing = globalHold
              ? BaseImageProvider.prepareForExit()
              : null;
          await _frame();
          expect(joined, isFalse);
          expect(codec.disposals, 0);
          expect(native.isCompleted, isFalse);
          native.complete(_Frame(second));
          await joining;
          if (preparing != null) releaseGlobal = await preparing;
          expect(visible, 1);
          expect(codec.reads, 2);
          expect(codec.disposals, 0);
          expect(cache.statusForKey(provider).keepAlive, isTrue);
          expect(BaseImageProvider.debugActiveLoadCount, 0);
          // A second release can finish while Flutter's pending frame delivery
          // is still waiting behind the global hold; no native request exists.
          final idle = BaseImageProvider.waitForReleasedStream(
            stream,
            waitForCurrentFrame: true,
          );
          await _frame();
          await idle;
          expect(codec.reads, 2);
        } finally {
          if (!native.isCompleted) native.complete(_Frame(second));
          cache.evict(provider, includeLive: true);
          await _frame();
          await BaseImageProvider.waitForReleasedStream(stream);
          releaseGlobal?.call();
          await _expectNoBufferedFailure();
        }
      },
    );
  }

  for (final failsBeforeFrame in [false, true]) {
    for (final globalHold in [false, true]) {
      test(
        'cached native failure retains original stack; before post-frame=$failsBeforeFrame global hold=$globalHold',
        () async {
          final native = Completer<ui.FrameInfo>();
          final first = await _image();
          late final _Codec codec;
          codec = _Codec(
            () =>
                codec.reads == 1 ? Future.value(_Frame(first)) : native.future,
            frameCount: 2,
          );
          final provider = _Provider(() async => Uint8List(1));
          final cache = PaintingBinding.instance.imageCache;
          final stream = ImageStream()
            ..setCompleter(
              cache.putIfAbsent(
                provider,
                () => provider.loadImage(provider, (
                  buffer, {
                  getTargetSize,
                }) async {
                  buffer.dispose();
                  return codec;
                }),
              )!,
            );
          final listener = _listener();
          stream.addListener(listener);
          final error = StateError('cached native frame failed');
          final stack = StackTrace.fromString('original cached native stack');
          final matcher = isA<ImageProviderPreparationFailure>().having(
            (failure) => failure.failures,
            'one original error and stack',
            [(error: error, stack: stack)],
          );
          final oldOnError = FlutterError.onError;
          // The raw cache stream has no UI listener after release. Verify its
          // diagnostic still identifies this same failure if Flutter reports it.
          final reported = <FlutterErrorDetails>[];
          FlutterError.onError = reported.add;
          try {
            await pumpEventQueue();
            await _frame();
            expect(codec.reads, 2);
            stream.removeListener(listener);
            final observed = expectLater(
              BaseImageProvider.waitForReleasedStream(
                stream,
                waitForCurrentFrame: true,
              ),
              throwsA(matcher),
            );
            final globalObserved = globalHold
                ? expectLater(
                    BaseImageProvider.prepareForExit(),
                    throwsA(matcher),
                  )
                : null;
            if (failsBeforeFrame) {
              native.completeError(error, stack);
              await pumpEventQueue();
            }
            await _frame();
            if (!failsBeforeFrame) native.completeError(error, stack);
            await observed;
            await globalObserved;
            for (final details in reported.where(
              (details) => details.library == 'image resource service',
            )) {
              expect(details.exception, same(error));
              expect(details.stack, same(stack));
            }
            expect(cache.statusForKey(provider).keepAlive, isTrue);
            await _expectNoBufferedFailure();
          } finally {
            if (!native.isCompleted) native.completeError(error, stack);
            cache.evict(provider, includeLive: true);
            await _frame();
            // A global preparation already received the failure concurrently;
            // disposal may still retain it locally, but must not replay it later.
            try {
              await BaseImageProvider.waitForReleasedStream(stream);
            } on ImageProviderPreparationFailure catch (failure) {
              expect(failure, matcher);
            }
            await _expectNoBufferedFailure();
            FlutterError.onError = oldOnError;
          }
        },
      );
    }
  }

  test(
    'a remaining listener owns the native frame even for an opted-in release',
    () async {
      final native = Completer<ui.FrameInfo>();
      final image = await _image();
      final codec = _Codec(() => native.future);
      final provider = _Provider(() async => Uint8List(1));
      final stream = _stream(provider, (buffer, {getTargetSize}) async {
        buffer.dispose();
        return codec;
      });
      final first = _listener();
      final other = _listener();
      stream.addListener(first);
      stream.addListener(other);
      await pumpEventQueue();
      expect(codec.reads, 1);
      stream.removeListener(first);
      await BaseImageProvider.waitForReleasedStream(
        stream,
        waitForCurrentFrame: true,
      );
      expect(native.isCompleted, isFalse);
      expect(codec.disposals, 0);
      stream.removeListener(other);
      final joining = BaseImageProvider.waitForReleasedStream(
        stream,
        waitForCurrentFrame: true,
      );
      native.complete(_Frame(image));
      await joining;
      expect(image.debugDisposed, isTrue);
      expect(codec.disposals, 1);
      await _expectNoBufferedFailure();
    },
  );

  test(
    'an opted-in native join retains decode and disposal errors for concurrent global preparation',
    () async {
      final native = Completer<ui.FrameInfo>();
      final nativeError = StateError('native decode failed');
      final nativeStack = StackTrace.fromString('original native decode');
      final disposalError = StateError('native disposal failed');
      final disposalStack = StackTrace.fromString('original native disposal');
      final codec = _Codec(
        () => native.future,
        disposeFailure: disposalError,
        disposeStack: disposalStack,
      );
      final provider = _Provider(() async => Uint8List(1));
      final stream = _stream(provider, (buffer, {getTargetSize}) async {
        buffer.dispose();
        return codec;
      });
      final handle = stream.completer!.keepAlive();
      final listener = _listener();
      stream.addListener(listener);
      await pumpEventQueue();
      stream.removeListener(listener);
      final observed = expectLater(
        BaseImageProvider.waitForReleasedStream(
          stream,
          waitForCurrentFrame: true,
        ),
        throwsA(
          isA<ImageProviderPreparationFailure>().having(
            (error) => error.failures,
            'two original failures',
            unorderedEquals([
              (error: nativeError, stack: nativeStack),
              (error: disposalError, stack: disposalStack),
            ]),
          ),
        ),
      );
      final globalObserved = expectLater(
        BaseImageProvider.prepareForExit(),
        throwsA(
          allOf(_containsFailure(nativeError), _containsFailure(disposalError)),
        ),
      );
      await _frame();
      handle.dispose();
      native.completeError(nativeError, nativeStack);
      await observed;
      await globalObserved;
      expect(codec.disposals, 1);
      await _expectNoBufferedFailure();
    },
  );

  for (final beforeFrame in [false, true]) {
    test(
      'released load keeps its original failure across cache retirement; before frame=$beforeFrame',
      () async {
        final read = Completer<Uint8List>();
        final error = StateError('Invalid Status Code: 404 after release');
        final stack = StackTrace.fromString('original released read failure');
        final provider = _Provider(() => read.future);
        final stream = provider.resolve(ImageConfiguration.empty);
        final listener = _listener();
        stream.addListener(listener);
        await pumpEventQueue();
        final cache = PaintingBinding.instance.imageCache;
        expect(cache.statusForKey(provider).pending, isTrue);
        cache.evict(provider, includeLive: false);
        stream.removeListener(listener);
        final observed = expectLater(
          BaseImageProvider.waitForReleasedStream(
            stream,
            waitForCurrentFrame: true,
          ),
          throwsA(
            isA<ImageProviderPreparationFailure>().having(
              (failure) => failure.failures,
              'one original error and stack',
              [(error: error, stack: stack)],
            ),
          ),
        );
        if (beforeFrame) {
          read.completeError(error, stack);
          await pumpEventQueue();
        }
        await _frame();
        if (!beforeFrame) read.completeError(error, stack);
        await observed;
        expect(provider.loads, 1);
        await _expectNoBufferedFailure();
      },
    );
  }

  test(
    'a released load snapshot hands ordinary errors to another listener',
    () async {
      final read = Completer<Uint8List>();
      final error = StateError('Invalid Status Code: 404 with another owner');
      final stack = StackTrace.fromString('remaining owner read');
      final provider = _Provider(() => read.future);
      final stream = _stream(provider, (buffer, {getTargetSize}) async {
        buffer.dispose();
        throw StateError('failed read must not decode');
      });
      final first = _listener();
      final errors = <({Object error, StackTrace? stack})>[];
      final other = ImageStreamListener(
        (image, _) => image.dispose(),
        onError: (Object error, StackTrace? stack) =>
            errors.add((error: error, stack: stack)),
      );
      stream.addListener(first);
      stream.addListener(other);
      stream.removeListener(first);
      await BaseImageProvider.waitForReleasedStream(
        stream,
        waitForCurrentFrame: true,
      );
      expect(read.isCompleted, isFalse);
      read.completeError(error, stack);
      await pumpEventQueue();
      expect(errors, [(error: error, stack: stack)]);
      stream.removeListener(other);
      // An error already delivered to an active owner does not become an exit
      // cleanup failure when that owner later releases its failed stream.
      await BaseImageProvider.waitForReleasedStream(
        stream,
        waitForCurrentFrame: true,
      );
      await _expectNoBufferedFailure();
    },
  );

  test(
    'a released load snapshot does not wait for a later global resume',
    () async {
      final read = Completer<Uint8List>();
      final provider = _Provider(() => read.future);
      var decodes = 0;
      final stream = _stream(provider, (buffer, {getTargetSize}) async {
        decodes++;
        buffer.dispose();
        throw StateError('cancelled read must not decode');
      });
      final handle = stream.completer!.keepAlive();
      final listener = _listener();
      stream.addListener(listener);
      stream.removeListener(listener);
      var joined = false;
      final joining = BaseImageProvider.waitForReleasedStream(
        stream,
        waitForCurrentFrame: true,
      ).then((_) => joined = true);
      final preparing = BaseImageProvider.prepareForExit();
      await _frame();
      expect(joined, isFalse);
      read.complete(Uint8List(1));
      await joining;
      final release = await preparing;
      expect(provider.loads, 1);
      expect(decodes, 0);
      expect(BaseImageProvider.debugActiveLoadCount, 0);
      handle.dispose();
      await BaseImageProvider.waitForReleasedStream(
        stream,
        waitForCurrentFrame: true,
      );
      release();
      await _expectNoBufferedFailure();
    },
  );
}
