import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:venera_next/network/request_scope.dart';

import 'base_image_provider.dart';
import 'image_provider_lifecycle.dart';

/// Capture the first frame as PNG, retaining its image through conversion and
/// joining this consumer's underlying work even when [scope] is cancelled.
Future<Uint8List> readImageProvider(
  ImageProvider provider, {
  required RequestScope scope,
  ImageConfiguration configuration = ImageConfiguration.empty,
}) => scope.runToCompletion(
  () => _ImageRead(provider, scope, configuration).run(),
);

class _ImageRead {
  _ImageRead(this.provider, this.scope, this.configuration);

  final ImageProvider provider;
  final RequestScope scope;
  final ImageConfiguration configuration;
  final _received = Completer<void>();
  final _detached = Completer<void>();
  final _failures = <({Object error, StackTrace stack})>[];
  final _reported = Set<Object>.identity();
  ({Object error, StackTrace stack})? _providerCancellation;
  Object? _key;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ImageInfo? _image;
  bool _initializing = false;
  bool _released = false;
  bool _finished = false;

  void _record(Object error, StackTrace stack) {
    if (BaseImageProvider.isCancellation(error)) {
      _providerCancellation ??= (error: error, stack: stack);
      return;
    }
    if (!_reported.add(error)) {
      return;
    }
    if (error is ImageProviderPreparationFailure) {
      for (final failure in error.failures) {
        _record(failure.error, failure.stack);
      }
    } else {
      _failures.add((error: error, stack: stack));
    }
  }

  Future<Uint8List> run() async {
    Uint8List? result;
    try {
      // Await the original key computation too. Cancellation before it finishes
      // must not start a new load later or guess which cache entry to release.
      final key = _key = await provider.obtainKey(configuration);
      scope.check();
      final stream = _stream = _ResolvedImageProvider(
        provider,
        key,
      ).resolve(configuration);
      final listener = _listener = ImageStreamListener(
        _onImage,
        onError: (Object error, StackTrace? stack) {
          _record(error, stack ?? StackTrace.current);
          _release();
        },
      );
      unawaited(
        scope.whenCancelled.then((_) {
          if (!_finished) _release();
        }),
      );
      _initializing = true;
      try {
        stream.addListener(listener);
      } finally {
        _initializing = false;
        if (_released) _detach();
      }
      if (scope.isCancelled) _release();
      await _received.future;
      final image = _image;
      if (image != null && !scope.isCancelled && _failures.isEmpty) {
        // Do not race this native conversion with cancellation: its ImageInfo
        // remains owned here until the actual Future has returned.
        final bytes = await image.image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (bytes == null) {
          throw StateError('Image conversion returned no bytes');
        }
        result = bytes.buffer.asUint8List(
          bytes.offsetInBytes,
          bytes.lengthInBytes,
        );
      }
    } catch (error, stack) {
      _record(error, stack);
    } finally {
      _release();
      await _detached.future;
      final image = _image;
      _image = null;
      try {
        image?.dispose();
      } catch (error, stack) {
        _record(error, stack);
      }
      _finished = true;
    }
    if (_failures.length == 1) {
      final failure = _failures.single;
      Error.throwWithStackTrace(failure.error, failure.stack);
    }
    if (_failures.isNotEmpty) throw ImageProviderPreparationFailure(_failures);
    scope.check();
    final cancellation = _providerCancellation;
    if (result == null && cancellation != null) {
      Error.throwWithStackTrace(cancellation.error, cancellation.stack);
    }
    return result!;
  }

  void _onImage(ImageInfo image, bool synchronous) {
    if (_released || scope.isCancelled) {
      try {
        image.dispose();
      } catch (error, stack) {
        _record(error, stack);
      }
      _release();
      return;
    }
    _image = image;
    _release();
  }

  void _release() {
    if (_released) return;
    _released = true;
    if (!_received.isCompleted) _received.complete();
    if (!_initializing) _detach();
  }

  void _detach() {
    final stream = _stream;
    final key = _key;
    try {
      final cache = PaintingBinding.instance.imageCache;
      if (stream != null && key != null && cache.statusForKey(key).pending) {
        // Reading only the pending branch avoids acquiring another cache handle.
        // A retired read cannot evict a same-key replacement's subscription.
        final cached = cache.putIfAbsent(
          key,
          () => throw StateError('Pending image disappeared before release'),
        );
        if (identical(cached, stream.completer)) {
          cache.evict(key, includeLive: false);
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
    unawaited(_finishDetach(stream));
  }

  Future<void> _finishDetach(ImageStream? stream) async {
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
      _detached.complete();
    }
  }
}

/// Resolve with the exact key already obtained by this read, preserving custom
/// provider stream creation and resolution without computing its key twice.
class _ResolvedImageProvider extends ImageProvider<Object> {
  _ResolvedImageProvider(this.provider, this.key);
  final ImageProvider provider;
  final Object key;

  @override
  Future<Object> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(key);

  @override
  ImageStream createStream(ImageConfiguration configuration) =>
      provider.createStream(configuration);

  @override
  void resolveStreamForKey(
    ImageConfiguration configuration,
    ImageStream stream,
    Object key,
    ImageErrorListener handleError,
  ) => provider.resolveStreamForKey(configuration, stream, key, handleError);
}
