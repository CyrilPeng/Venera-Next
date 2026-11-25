import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'image_position.dart';

/// A hit-tested original image and its read port, captured synchronously before
/// file/cache I/O. Display grouping and later chapter changes cannot alter it.
class ReaderImageRead {
  const ReaderImageRead({
    required this.address,
    required this.imageNumber,
    required this.readBytes,
  });

  final ReaderImageAddress address;
  final int imageNumber;
  final Future<Uint8List?> Function(ReaderImageAddress) readBytes;

  Future<Uint8List?> read() => readBytes(address);
}

/// Reads the original address and keeps the accepted cache/file Future. The
/// caller's ImageWork owns cancellation and waits for its actual completion.
Future<Uint8List?> readReaderImageBytes(ReaderImageAddress image) async {
  if (image.imageKey.startsWith('file://')) {
    return File(image.imageKey.substring(7)).readAsBytes();
  }
  final file = await CacheManager().findCache(image.cacheKey);
  return file?.readAsBytes();
}
