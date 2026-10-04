import 'dart:async';

import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';
import 'package:venera_next/foundation/image_provider/base_image_provider.dart';
import 'package:venera_next/foundation/image_provider/image_provider_lifecycle.dart';
import 'package:venera_next/foundation/image_provider/reader_image.dart';

import 'package:venera_next/foundation/image_work.dart';

/// Decoded prefetch listeners belonging to one view and its reading session.
class ReaderImagePrecache {
  ReaderImagePrecache({required ImageWork work}) : _work = work;

  final ImageWork _work;
  final _pending = <ReaderImageProvider, _ReaderPrecacheEntry>{};
  Future<void>? _disposal;

  void preload(ReaderImageProvider provider, ImageConfiguration configuration) {
    if (_disposal != null || _pending.containsKey(provider)) return;
    late final _ReaderPrecacheEntry entry;
    final task = _work.start(onCancel: () => entry.release());
    if (task == null) return;
    entry = _ReaderPrecacheEntry(
      provider,
      task,
      () => _pending.remove(provider),
    );
    _pending[provider] = entry;
    entry.resolve(configuration);
  }

  Future<void> dispose() {
    if (_disposal != null) return _disposal!;
    final pending = _pending.values.toList();
    final completion = Completer<void>();
    _disposal = completion.future;
    for (final entry in pending) {
      entry.task.cancel();
    }
    completion.complete(
      Future.wait(pending.map((e) => e.task.done)).then((_) {}),
    );
    return completion.future;
  }
}

class _ReaderPrecacheEntry {
  _ReaderPrecacheEntry(this.provider, this.task, this.onFinished);

  final ReaderImageProvider provider;
  final ImageWorkTask task;
  final void Function() onFinished;
  final _reported = Set<Object>.identity();
  ImageStream? _stream;
  ImageStreamListener? _listener;
  bool _initializing = true;
  bool _released = false;
  bool _received = false;

  void _record(Object error, StackTrace stack) {
    if (BaseImageProvider.isCancellation(error) || !_reported.add(error)) {
      return;
    }
    if (error is ImageProviderPreparationFailure) {
      for (final failure in error.failures) {
        _record(failure.error, failure.stack);
      }
      return;
    }
    task.recordFailure(error, stack);
  }

  void resolve(ImageConfiguration configuration) {
    try {
      final stream = _stream = provider.resolve(configuration);
      final listener = _listener = ImageStreamListener(
        (image, synchronous) {
          try {
            image.dispose();
          } catch (error, stack) {
            _record(error, stack);
          }
          if (_received) return;
          _received = true;
          // Retain the decoded image for one frame so a visible widget can use it.
          SchedulerBinding.instance.addPostFrameCallback((_) => release());
        },
        onError: (Object error, StackTrace? stack) {
          if (task.isCancelled || BaseImageProvider.isCleanupFailure(error)) {
            _record(error, stack ?? StackTrace.current);
          }
          release();
        },
      );
      stream.addListener(listener);
    } catch (error, stack) {
      _record(error, stack);
      release();
    } finally {
      _initializing = false;
      if (_released) _releaseNow();
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
      if (stream != null && cache.statusForKey(provider).pending) {
        // The synchronous pending branch only reads the existing completer.
        // An old entry must not evict a replacement registered under this key.
        final pending = cache.putIfAbsent(
          provider,
          () => throw StateError('Pending precache stream disappeared'),
        );
        if (identical(pending, stream.completer)) {
          cache.evict(provider, includeLive: false);
        }
      }
    } catch (error, stack) {
      _record(error, stack);
    }
    try {
      final listener = _listener;
      if (stream != null && listener != null) stream.removeListener(listener);
    } catch (error, stack) {
      _record(error, stack);
    }
    unawaited(_finish(stream));
  }

  Future<void> _finish(ImageStream? stream) async {
    try {
      if (stream != null) {
        await BaseImageProvider.waitForReleasedStream(stream);
      }
    } catch (error, stack) {
      _record(error, stack);
    } finally {
      onFinished();
      task.finish();
    }
  }
}
