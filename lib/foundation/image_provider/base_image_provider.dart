import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' show FileSystemException;
import 'dart:math';
import 'dart:ui' as ui show Codec;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:dio/dio.dart' show CancelToken, DioException;
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/request_scope.dart';
import 'package:venera_next/network/image_loading_config.dart';
import 'package:venera_next/network/image_http_client.dart';
import 'package:venera_next/network/image_stream.dart';

import 'image_provider_lifecycle.dart';

abstract class BaseImageProvider<T extends BaseImageProvider<T>>
    extends ImageProvider<T> {
  const BaseImageProvider();

  static final _lifecycle = ImageProviderLifecycle();

  static Future<VoidCallback> prepareForExit() => _lifecycle.prepareForExit();

  /// Call after releasing a listener/cache reference. If another listener or
  /// cache handle still owns the stream, its work remains with that owner.
  /// Otherwise join this stream's actual loading and native frame cleanup.
  /// Visible consumers can also snapshot the current load and native frame
  /// before cache handles retire, retaining their original failures. A frame
  /// already in flight is joined without evicting a successful cache entry.
  static Future<void> waitForReleasedStream(
    ImageStream stream, {
    bool waitForCurrentFrame = false,
  }) {
    final completer = stream.completer;
    return completer is _CancellableImageStreamCompleter
        ? completer.waitForRelease(waitForCurrentFrame: waitForCurrentFrame)
        : Future.value();
  }

  @visibleForTesting
  static int get debugActiveLoadCount => _lifecycle.activeCount;

  static bool isCancellation(Object error) =>
      error is ImageProviderLoadCancelled ||
      error is RequestCancelled ||
      (error is DioException && CancelToken.isCancel(error));

  static bool isCleanupFailure(Object error) =>
      error is ImageLoadingConfigFailure ||
      error is ImageLoadingConfigCleanupFailure ||
      error is ImageHttpCleanupFailure ||
      error is ImageStreamCleanupFailure ||
      error is ImageProviderPreparationFailure;

  /// Check whether another stage may start without replacing the failure which
  /// led here with a cancellation exception. The caller retains that failure.
  static bool canRetryAfterFailure(void Function() checkStop) {
    try {
      checkStop();
      return true;
    } catch (_) {
      return false;
    }
  }

  static final Expando<Future<void>> _cancelSignals = Expando<Future<void>>();

  static final Future<void> _neverCancelSignal = Completer<void>().future;

  static Future<void> cancelSignalOf(void Function() checkStop) {
    return _cancelSignals[checkStop] ?? _neverCancelSignal;
  }

  @visibleForTesting
  static Future<void> debugWaitForRetryDelay(
    Duration duration,
    Future<void> cancelSignal,
  ) {
    return _waitForRetryDelay(duration, cancelSignal);
  }

  static Future<void> _waitForRetryDelay(
    Duration duration,
    Future<void> cancelSignal,
  ) {
    return Future.any([Future<void>.delayed(duration), cancelSignal]);
  }

  static const int maxImagePixel = 2560 * 1440;

  static TargetImageSize _getTargetSize(int width, int height) {
    // ignore invalid size
    if (width <= 0 || height <= 0) {
      return TargetImageSize(width: width, height: height);
    }
    // ignore too wide or too tall image
    final imageRatio = width / height;
    if (imageRatio > 2 || imageRatio < 0.5) {
      return TargetImageSize(width: width, height: height);
    }
    // resize if too large
    if (width * height > maxImagePixel) {
      final ratio = sqrt(maxImagePixel / (width * height));
      return TargetImageSize(
        width: (width * ratio).round(),
        height: (height * ratio).round(),
      );
    }
    return TargetImageSize(width: width, height: height);
  }

  @override
  ImageStreamCompleter loadImage(T key, ImageDecoderCallback decode) {
    final chunkEvents = StreamController<ImageChunkEvent>();
    final consumer = _ImageConsumer();
    late final ImageStreamCompleter completer;
    void evictOwnedStream() {
      final cache = PaintingBinding.instance.imageCache;
      if (!cache.statusForKey(key).pending) return;
      // Only the pending branch is a read: completed/live hits can create new
      // cache handles. An uncompleted load cannot own a completed cache entry;
      // live-only streams remain with their listeners after explicit eviction.
      // A retired load's failure must not affect a same-key replacement.
      final cached = cache.putIfAbsent(
        key,
        () => throw StateError('Cached image disappeared before eviction'),
      );
      if (identical(cached, completer)) cache.evict(key);
    }

    completer = _CancellableImageStreamCompleter(
      consumer: consumer,
      codec: _loadBufferAsync(chunkEvents, decode, consumer, evictOwnedStream),
      chunkEvents: chunkEvents.stream,
      scale: 1.0,
      informationCollector: () sync* {
        yield DiagnosticsProperty<ImageProvider>(
          'Image provider: $this \n Image key: $key',
          this,
          style: DiagnosticsTreeStyle.errorProperty,
        );
      },
    );
    return completer;
  }

  Future<ui.Codec> _loadBufferAsync(
    StreamController<ImageChunkEvent> chunkEvents,
    ImageDecoderCallback decode,
    _ImageConsumer consumer,
    VoidCallback evictOwnedStream,
  ) async {
    try {
      while (true) {
        if (_lifecycle.isHeld) {
          await _lifecycle.waitUntilReady(
            consumerCancelled: consumer.whenCancelled,
            isConsumerCancelled: () => consumer.isCancelled,
          );
        }
        consumer.check();
        final attempt = _lifecycle.tryBegin();
        if (attempt == null) continue;
        consumer.active = attempt;
        Object? failure;
        StackTrace? failureStack;
        try {
          final loading = _loadAttempt(chunkEvents, decode, attempt);
          consumer.loading = (load: loading, attempt: attempt);
          final codec = await loading;
          if (attempt.isCancelled) {
            codec.dispose();
            attempt.check();
          }
          final owned = _OwnedImageCodec(codec, consumer.recordFailure);
          consumer.codec = owned;
          return owned;
        } catch (error, stack) {
          if ((attempt.isCancelled && !isCancellation(error)) ||
              isCleanupFailure(error)) {
            failure = error;
            failureStack = stack;
          }
          if (!attempt.isCancelled || !isCancellation(error)) rethrow;
          consumer.check();
          // A live Flutter stream waits for explicit shutdown recovery. This
          // does not retry cancelled work while admission is held.
        } finally {
          consumer.active = null;
          if (failure != null) consumer.recordFailure(failure, failureStack!);
          attempt.finish(error: failure, stack: failureStack);
          consumer.loading = null;
        }
      }
    } catch (e, s) {
      if (isCancellation(e)) rethrow;
      scheduleMicrotask(evictOwnedStream);
      Log.error("Image Loading", e, s);
      rethrow;
    } finally {
      chunkEvents.close();
      consumer.finishLoading();
    }
  }

  Future<ui.Codec> _loadAttempt(
    StreamController<ImageChunkEvent> chunkEvents,
    ImageDecoderCallback decode,
    ImageProviderLoadAttempt attempt,
  ) async {
    void checkStop() => attempt.check();
    _cancelSignals[checkStop] = attempt.whenCancelled;
    int retryTime = 1;
    Uint8List? data;
    var emptyRetries = 0;
    while (data == null) {
      attempt.check();
      try {
        final loaded = await load(chunkEvents, checkStop);
        attempt.check();
        if (loaded.isEmpty) {
          if (emptyRetries++ >= 2) throw const _EmptyImageDataException();
          await _waitForRetryDelay(
            Duration(milliseconds: 150 * emptyRetries),
            attempt.whenCancelled,
          );
          continue;
        }
        data = loaded;
      } catch (error) {
        if (isCancellation(error) ||
            isCleanupFailure(error) ||
            attempt.isCancelled) {
          rethrow;
        }
        if (error is _EmptyImageDataException) rethrow;
        if (error is FileSystemException && !retryFileSystemErrors) rethrow;
        if (error.toString().contains('Invalid Status Code: 404') ||
            error.toString().contains('Invalid Status Code: 403')) {
          rethrow;
        }
        if (error.toString().contains('handshake') && retryTime < 5) {
          retryTime = 5;
        }
        retryTime <<= 1;
        if (retryTime > (1 << 3)) rethrow;
        await _waitForRetryDelay(
          Duration(seconds: retryTime),
          attempt.whenCancelled,
        );
      }
    }
    attempt.check();
    final bytes = data;
    try {
      final buffer = await ImmutableBuffer.fromUint8List(bytes);
      if (attempt.isCancelled) {
        buffer.dispose();
        attempt.check();
      }
      // Flutter's decoder takes ownership on invocation. Only a buffer which
      // never reaches decode above belongs to this provider for disposal.
      return await decode(
        buffer,
        getTargetSize: enableResize ? _getTargetSize : null,
      );
    } catch (error) {
      if (attempt.isCancelled || isCancellation(error)) rethrow;
      await CacheManager().delete(key);
      if (bytes.length < 2 * 1024) {
        try {
          var text = const Utf8Codec(
            allowMalformed: false,
          ).decoder.convert(bytes);
          throw Exception('Expected image data, but got text: $text');
        } catch (_) {
          // Invalid bytes keep their original decoder failure.
        }
      }
      rethrow;
    }
  }

  Future<Uint8List> load(
    StreamController<ImageChunkEvent> chunkEvents,
    void Function() checkStop,
  );

  String get key;

  @override
  bool operator ==(Object other) {
    return other is BaseImageProvider<T> && key == other.key;
  }

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() {
    return "$runtimeType($key)";
  }

  bool get enableResize => false;

  bool get retryFileSystemErrors => true;
}

class _EmptyImageDataException implements Exception {
  const _EmptyImageDataException();

  @override
  String toString() => 'Empty image data after 3 attempts';
}

typedef _ImageLoadRequest = ({
  Future<ui.Codec> load,
  ImageProviderLoadAttempt attempt,
});

class _ImageConsumer {
  final _cancelled = Completer<void>();
  final _loadingDone = Completer<void>();
  final _failures = <({Object error, StackTrace stack})>[];
  Future<void>? _cleanup;
  ImageProviderLoadAttempt? active;
  _ImageLoadRequest? loading;
  _OwnedImageCodec? codec;
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;

  void recordFailure(Object error, StackTrace stack) {
    if (_failures.any((failure) => identical(failure.error, error))) return;
    _failures.add((error: error, stack: stack));
  }

  void finishLoading() => _loadingDone.complete();

  Future<void> joinCleanup() => _cleanup ??= _joinCleanup();

  Future<void> joinCurrentLoad(_ImageLoadRequest loading) =>
      _joinReleasedImageWork([
        loading.load.then<void>((_) {}),
        loading.attempt.done,
      ]);

  Future<void> _joinCleanup() async {
    await _loadingDone.future;
    await codec?.closed;
    for (final failure in _failures) {
      BaseImageProvider._lifecycle.consumeCleanupFailure(
        failure.error,
        failure.stack,
      );
    }
    if (_failures.isNotEmpty) throw ImageProviderPreparationFailure(_failures);
  }

  void check() {
    if (isCancelled) throw const ImageProviderLoadCancelled();
  }

  void cancel() {
    if (isCancelled) return;
    _cancelled.complete();
    active?.cancel();
    codec?.dispose();
  }
}

typedef _NativeImageFrame = ({
  Future<FrameInfo> frame,
  ImageProviderLoadAttempt attempt,
});

/// Flutter owns animation scheduling; this adapter owns each native frame
/// request until its image is handed to Flutter or discarded after cancellation.
class _OwnedImageCodec implements ui.Codec {
  _OwnedImageCodec(this._raw, this._recordFailure)
    : frameCount = _raw.frameCount,
      repetitionCount = _raw.repetitionCount;

  final ui.Codec _raw;
  final void Function(Object, StackTrace) _recordFailure;
  final _closed = Completer<void>();
  Future<void> get closed => _closed.future;
  @override
  final int frameCount;
  @override
  final int repetitionCount;
  final _cancelled = Completer<void>();
  final _requests = Queue<Completer<FrameInfo>>();
  ImageProviderLoadAttempt? _active;
  _NativeImageFrame? _nativeFrame;
  FrameInfo? _pendingFrame;
  bool _working = false;
  bool _rawDisposed = false;
  bool get _disposed => _cancelled.isCompleted;

  Future<void> waitForCurrentFrame(_NativeImageFrame frame) async {
    // The Flutter request can remain queued behind a reversible global hold
    // after native decoding has finished. Join only this original native call
    // and its finally block; neither its eventual delivery nor another frame.
    await _joinReleasedImageWork([
      frame.frame.then<void>((_) {}),
      frame.attempt.done,
    ]);
  }

  @override
  Future<FrameInfo> getNextFrame() {
    // Completing synchronously transfers the frame to an already waiting
    // MultiFrameImageStreamCompleter before the attempt is marked drained.
    final completion = Completer<FrameInfo>.sync();
    _requests.add(completion);
    if (!_working) unawaited(_drainRequests());
    return completion.future;
  }

  Future<void> _drainRequests() async {
    _working = true;
    try {
      while (_requests.isNotEmpty) {
        await _readFrame(_requests.removeFirst());
      }
    } finally {
      _working = false;
      _completeClose();
    }
  }

  Future<void> _readFrame(Completer<FrameInfo> completion) async {
    while (true) {
      try {
        await BaseImageProvider._lifecycle.waitUntilReady(
          consumerCancelled: _cancelled.future,
          isConsumerCancelled: () => _disposed,
        );
      } catch (error, stack) {
        completion.completeError(error, stack);
        return;
      }
      final attempt = BaseImageProvider._lifecycle.tryBegin();
      if (attempt == null) continue;
      _active = attempt;
      FrameInfo? frame;
      Object? error;
      StackTrace? stack;
      void recordFailure(Object failure, StackTrace failureStack) {
        if (error == null || BaseImageProvider.isCancellation(error!)) {
          error = failure;
          stack = failureStack;
        } else {
          error = ImageProviderPreparationFailure([
            (error: error!, stack: stack!),
            (error: failure, stack: failureStack),
          ]);
        }
      }

      try {
        frame = _pendingFrame;
        _pendingFrame = null;
        if (frame == null) {
          final native = _raw.getNextFrame();
          _nativeFrame = (frame: native, attempt: attempt);
          frame = await native;
        }
        if (attempt.isCancelled && !_disposed) {
          // Native decode has finished, but a reversible hold must preserve
          // frame order. This static image is owned here until recovery or
          // final disposal, without keeping any native work active.
          _pendingFrame = frame;
          frame = null;
        }
        attempt.check();
        final delivered = frame;
        frame = null;
        completion.complete(delivered);
      } catch (failure, failureStack) {
        recordFailure(failure, failureStack);
      } finally {
        if (frame != null) {
          try {
            frame.image.dispose();
          } catch (failure, failureStack) {
            recordFailure(failure, failureStack);
          }
        }
        if (_disposed) {
          try {
            _disposeResources();
          } catch (failure, failureStack) {
            recordFailure(failure, failureStack);
          }
        }
        _active = null;
        final failedCleanup =
            attempt.isCancelled &&
            error != null &&
            !BaseImageProvider.isCancellation(error!);
        if (failedCleanup) _recordFailure(error!, stack!);
        attempt.finish(
          error: failedCleanup ? error : null,
          stack: failedCleanup ? stack : null,
        );
        if (identical(_nativeFrame?.attempt, attempt)) _nativeFrame = null;
      }
      if (completion.isCompleted) {
        if (error != null && !BaseImageProvider.isCancellation(error!)) {
          Log.error('Image decoding cleanup', error!, stack);
        }
        return;
      }
      if (attempt.isCancelled &&
          error != null &&
          BaseImageProvider.isCancellation(error!) &&
          !_disposed) {
        continue;
      }
      completion.completeError(error!, stack);
      return;
    }
  }

  void _disposeResources() {
    final failures = <({Object error, StackTrace stack})>[];
    final pending = _pendingFrame;
    _pendingFrame = null;
    try {
      pending?.image.dispose();
    } catch (error, stack) {
      failures.add((error: error, stack: stack));
    }
    if (!_rawDisposed) {
      _rawDisposed = true;
      try {
        _raw.dispose();
      } catch (error, stack) {
        failures.add((error: error, stack: stack));
      }
    }
    if (failures.isNotEmpty) throw ImageProviderPreparationFailure(failures);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _cancelled.complete();
    final active = _active;
    if (active != null) {
      active.cancel();
    } else {
      try {
        _disposeResources();
      } catch (error, stack) {
        _recordFailure(error, stack);
        BaseImageProvider._lifecycle.recordCleanupFailure(error, stack);
        rethrow;
      } finally {
        _completeClose();
      }
    }
  }

  void _completeClose() {
    if (_disposed && !_working && !_closed.isCompleted) _closed.complete();
  }
}

Future<void> _joinReleasedImageWork(Iterable<Future<void>> work) async {
  final failures = <({Object error, StackTrace stack})>[];
  final seen = Set<Object>.identity();
  void record(Object error, StackTrace stack) {
    BaseImageProvider._lifecycle.consumeCleanupFailure(error, stack);
    if (error is ImageProviderPreparationFailure) {
      for (final failure in error.failures) {
        record(failure.error, failure.stack);
      }
    } else if (!BaseImageProvider.isCancellation(error) && seen.add(error)) {
      failures.add((error: error, stack: stack));
    }
  }

  await Future.wait([for (final future in work) future.catchError(record)]);
  if (failures.isNotEmpty) throw ImageProviderPreparationFailure(failures);
}

/// Cancellation is expected after the final consumer releases an image.
class _CancellableImageStreamCompleter extends MultiFrameImageStreamCompleter {
  _CancellableImageStreamCompleter({
    required _ImageConsumer consumer,
    required super.codec,
    required super.chunkEvents,
    required super.scale,
    super.informationCollector,
  }) : _consumer = consumer {
    _unlisten = BaseImageProvider._lifecycle.listen(
      hold: () {},
      resume: _resumeImage,
    );
  }

  final _ImageConsumer _consumer;
  late final VoidCallback _unlisten;
  ImageInfo? _heldImage;
  bool _disposed = false;

  Future<void> waitForRelease({bool waitForCurrentFrame = false}) async {
    final codec = _consumer.codec;
    // Snapshot before the post-frame wait, including failures which settle
    // before cache handles are retired. A later animation request is not ours.
    final loading = waitForCurrentFrame ? _consumer.loading : null;
    final native = waitForCurrentFrame ? codec?._nativeFrame : null;
    if (!_disposed && !hasListeners) {
      // ImageCache releases retired live/cache handles after the frame. A fresh
      // callback checks after those releases, including when endOfFrame already
      // exists. Remaining handles then belong to other consumers or the cache.
      final released = Completer<void>();
      SchedulerBinding.instance.addPostFrameCallback(
        (_) => released.complete(),
      );
      SchedulerBinding.instance.ensureVisualUpdate();
      await released.future;
    }
    await _joinReleasedImageWork([
      if (_disposed) _consumer.joinCleanup(),
      if (loading != null && !hasListeners) _consumer.joinCurrentLoad(loading),
      if (native != null && !hasListeners) codec!.waitForCurrentFrame(native),
    ]);
  }

  @override
  void setImage(ImageInfo image) {
    if (_disposed) {
      image.dispose();
      return;
    }
    _heldImage?.dispose();
    _heldImage = null;
    if (BaseImageProvider._lifecycle.isHeld) {
      _heldImage = image;
    } else {
      super.setImage(image);
    }
  }

  void _resumeImage() {
    if (BaseImageProvider._lifecycle.isHeld) return;
    final image = _heldImage;
    if (image == null) return;
    _heldImage = null;
    if (_disposed) {
      image.dispose();
    } else {
      super.setImage(image);
    }
  }

  @override
  void onDisposed() {
    _disposed = true;
    final failures = <({Object error, StackTrace stack})>[];
    try {
      _consumer.cancel();
    } catch (error, stack) {
      // The codec has registered its failed cleanup with the lifecycle. Do not
      // interrupt Flutter's own subscription/codec cleanup after this hook.
      failures.add((error: error, stack: stack));
      _consumer.recordFailure(error, stack);
    } finally {
      _unlisten();
      final heldImage = _heldImage;
      _heldImage = null;
      try {
        heldImage?.dispose();
      } catch (error, stack) {
        BaseImageProvider._lifecycle.recordCleanupFailure(error, stack);
        _consumer.recordFailure(error, stack);
        failures.add((error: error, stack: stack));
      }
      super.onDisposed();
    }
    for (final failure in failures) {
      Log.error('Disposed image cleanup', failure.error, failure.stack);
    }
  }

  @override
  void reportError({
    DiagnosticsNode? context,
    required Object exception,
    StackTrace? stack,
    InformationCollector? informationCollector,
    bool silent = false,
  }) {
    if (BaseImageProvider.isCancellation(exception)) return;
    if (_disposed) {
      Log.error('Disposed image cleanup', exception, stack);
      return;
    }
    super.reportError(
      context: context,
      exception: exception,
      stack: stack,
      informationCollector: informationCollector,
      silent: silent,
    );
  }
}
