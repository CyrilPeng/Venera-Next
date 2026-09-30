/// Memory-based cache sizing for one reader lifetime. The platform owns the
/// memory query and the application image cache; queries cannot be aborted.
class ReaderImageCachePolicy {
  ReaderImageCachePolicy({
    required this.readAvailableMemory,
    required this.setLimit,
    required this.onError,
    this.onConfigured,
  });

  static const defaultLimit = 100 << 20;

  static int limitForMemory(int availableBytes) {
    if (availableBytes < 1 << 30) return defaultLimit;
    if (availableBytes < 2 << 30) return 200 << 20;
    if (availableBytes < 4 << 30) return 300 << 20;
    return 500 << 20;
  }

  final Future<int?> Function() readAvailableMemory;
  final void Function(int bytes) setLimit;
  final void Function(Object, StackTrace) onError;
  final void Function(int availableBytes, int limit)? onConfigured;
  var _generation = 0;
  var _disposed = false;

  Future<void> configure() async {
    if (_disposed) return;
    final generation = ++_generation;
    try {
      final memory = await readAvailableMemory();
      if (_disposed || generation != _generation || memory == null) return;
      final limit = limitForMemory(memory);
      setLimit(limit);
      onConfigured?.call(memory, limit);
    } catch (error, stack) {
      if (!_disposed && generation == _generation) onError(error, stack);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_generation;
    setLimit(defaultLimit);
  }
}
