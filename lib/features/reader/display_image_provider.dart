import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:venera_next/foundation/image_provider/base_image_provider.dart';
import 'package:venera_next/foundation/image_provider/image_provider_lifecycle.dart';
import 'package:venera_next/foundation/image_provider/reader_image.dart';

import 'package:venera_next/foundation/image_work.dart';

/// A reader's visible consumers share this forwarding stream. The underlying
/// provider retains its original cache key and Flutter's animation scheduling.
/// Only the underlying subscription is suspended during reversible exit holds.
class ReaderDisplayImageProvider
    extends ImageProvider<ReaderDisplayImageProvider> {
  ReaderDisplayImageProvider(this.image, this.work);

  final ReaderImageProvider image;
  final ImageWork work;
  _ReaderDisplayStream? _stream;

  String get imageKey => image.imageKey;

  @override
  Future<ReaderDisplayImageProvider> obtainKey(
    ImageConfiguration configuration,
  ) => SynchronousFuture(this);

  @override
  void resolveStreamForKey(
    ImageConfiguration configuration,
    ImageStream stream,
    ReaderDisplayImageProvider key,
    ImageErrorListener handleError,
  ) {
    var owned = _stream;
    if (owned == null || owned.disposed || owned.failed) {
      owned = _stream = _ReaderDisplayStream(image, work, configuration);
    }
    // This relay must not acquire a global ImageCache keepAlive. Its underlying
    // stream already participates in that cache, shared with other readers.
    stream.setCompleter(owned);
  }

  @override
  bool operator ==(Object other) =>
      other is ReaderDisplayImageProvider &&
      image == other.image &&
      identical(work, other.work);

  @override
  int get hashCode => Object.hash(image, identityHashCode(work));
}

class _ReaderDisplayStream extends ImageStreamCompleter {
  _ReaderDisplayStream(this.image, this.work, this.configuration);

  final ReaderImageProvider image;
  final ImageWork work;
  final ImageConfiguration configuration;
  void Function()? _removeResume;
  _DisplayImageAttempt? _attempt;
  bool disposed = false;
  bool failed = false;

  @override
  void addListener(ImageStreamListener listener) {
    _removeResume ??= work.addResumeListener(_start);
    super.addListener(listener);
    _start();
  }

  @override
  void removeListener(ImageStreamListener listener) {
    super.removeListener(listener);
    // A keepAlive can retain this relay across multiple listener cycles.
    // Flutter clears last-listener callbacks after each cycle.
    if (!hasListeners) _attempt?.task.cancel();
  }

  void _start() {
    if (disposed || failed || !hasListeners || _attempt != null) return;
    late final _DisplayImageAttempt attempt;
    final task = work.start(onCancel: () => attempt.release());
    if (task == null) return;
    attempt = _DisplayImageAttempt(this, task);
    _attempt = attempt;
    attempt.resolve();
  }

  void finished(_DisplayImageAttempt attempt) {
    if (!identical(_attempt, attempt)) return;
    _attempt = null;
    _start();
  }

  bool accepts(_DisplayImageAttempt attempt) =>
      !disposed && identical(_attempt, attempt) && !attempt.task.isCancelled;

  void receiveImage(ImageInfo info) => setImage(info);
  void receiveChunk(ImageChunkEvent event) => reportImageChunkEvent(event);

  @override
  void onDisposed() {
    disposed = true;
    _removeResume?.call();
    _attempt?.task.cancel();
    super.onDisposed();
  }
}

class _DisplayImageAttempt {
  _DisplayImageAttempt(this.owner, this.task);

  final _ReaderDisplayStream owner;
  final ImageWorkTask task;
  final _reported = Set<Object>.identity();
  ImageStream? _stream;
  ImageStreamListener? _listener;
  bool _initializing = true;
  bool _released = false;

  void _record(Object error, StackTrace stack) {
    if (BaseImageProvider.isCancellation(error) || !_reported.add(error)) {
      return;
    }
    if (error is ImageProviderPreparationFailure) {
      for (final failure in error.failures) {
        _record(failure.error, failure.stack);
      }
    } else {
      task.recordFailure(error, stack);
    }
  }

  void resolve() {
    try {
      final stream = _stream = owner.image.resolve(owner.configuration);
      final listener = _listener = ImageStreamListener(
        (info, synchronous) {
          if (_released || !owner.accepts(this)) {
            info.dispose();
            return;
          }
          owner.receiveImage(info);
        },
        onChunk: (event) {
          if (!_released && owner.accepts(this)) {
            owner.receiveChunk(event);
          }
        },
        onError: (Object error, StackTrace? stack) {
          _fail(error, stack ?? StackTrace.current);
        },
      );
      stream.addListener(listener);
    } catch (error, stack) {
      _fail(error, stack);
    } finally {
      _initializing = false;
      if (_released) _releaseNow();
    }
  }

  void _fail(Object error, StackTrace stack) {
    if (task.isCancelled || BaseImageProvider.isCleanupFailure(error)) {
      _record(error, stack);
    }
    try {
      if (!_released && owner.accepts(this)) {
        owner.failed = true;
        owner.reportError(exception: error, stack: stack);
      }
    } finally {
      release();
    }
  }

  void release() {
    if (_released) return;
    _released = true;
    if (!_initializing) _releaseNow();
  }

  void _releaseNow() {
    final stream = _stream;
    try {
      final cache = PaintingBinding.instance.imageCache;
      if (stream != null && cache.statusForKey(owner.image).pending) {
        final pending = cache.putIfAbsent(
          owner.image,
          () => throw StateError('Pending display image disappeared'),
        );
        if (identical(pending, stream.completer)) {
          cache.evict(owner.image, includeLive: false);
        }
      }
    } catch (error, stack) {
      _record(error, stack);
    }
    try {
      if (stream != null && _listener != null) {
        stream.removeListener(_listener!);
      }
    } catch (error, stack) {
      _record(error, stack);
    }
    unawaited(_finish(stream));
  }

  Future<void> _finish(ImageStream? stream) async {
    try {
      if (stream != null) {
        await BaseImageProvider.waitForReleasedStream(
          stream,
          waitForCurrentFrame: true,
        );
      }
    } catch (error, stack) {
      _record(error, stack);
    } finally {
      task.finish();
      owner.finished(this);
    }
  }
}
