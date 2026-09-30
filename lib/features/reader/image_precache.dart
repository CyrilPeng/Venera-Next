import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';
import 'package:venera_next/foundation/image_provider/reader_image.dart';

/// Decoded prefetch listeners belonging to one gallery view.
class ReaderImagePrecache {
  final _pending = <ReaderImageProvider, void Function()>{};
  bool _disposed = false;

  void preload(ReaderImageProvider provider, ImageConfiguration configuration) {
    if (_disposed || _pending.containsKey(provider)) return;
    // ReaderImageProvider synchronously resolves to itself as the cache key.
    final stream = provider.resolve(configuration);
    late ImageStreamListener listener;
    var released = false;
    var received = false;
    void release() {
      if (released) return;
      released = true;
      _pending.remove(provider);
      final cache = PaintingBinding.instance.imageCache;
      if (cache.statusForKey(provider).pending) {
        // Drop the cache's pending listener, retaining live consumers. Removing
        // our own listener below disposes the completer only when nobody needs it.
        cache.evict(provider, includeLive: false);
      }
      stream.removeListener(listener);
    }

    listener = ImageStreamListener((image, synchronous) {
      image.dispose();
      if (received) return;
      received = true;
      // Keep one frame for a visible widget to acquire the decoded image.
      SchedulerBinding.instance.addPostFrameCallback((_) => release());
    }, onError: (Object error, StackTrace? stack) => release());
    _pending[provider] = release;
    stream.addListener(listener);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final release in _pending.values.toList()) {
      release();
    }
  }
}
