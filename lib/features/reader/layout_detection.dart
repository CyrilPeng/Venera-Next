import 'dart:async';
import 'dart:ui' as ui;

import 'package:venera_next/foundation/comic_layout.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'package:venera_next/network/images.dart';

/// Reads encoded image dimensions without decoding full comic bitmaps.
/// Network requests share the reader's downloader and disk cache.
class ComicLayoutProbe {
  final _readers = <StreamIterator<ImageDownloadProgress>>{};
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    for (final reader in _readers.toList()) {
      unawaited(reader.cancel());
    }
    _readers.clear();
  }

  Future<ComicLayoutDetection> detect({
    required List<String> images,
    required String? sourceKey,
    required String comicId,
    required String chapterId,
  }) async {
    // The first image often is a cover. Never classify from it alone.
    final sample = images
        .skip(1)
        .take(ComicLayoutDetection.maxSamples)
        .toList();
    if (sample.length < ComicLayoutDetection.minSamples) {
      return const ComicLayoutDetection(ComicLayout.unknown, 0);
    }
    final ratios = await Future.wait(
      sample.map((image) => _readRatio(image, sourceKey, comicId, chapterId)),
    );
    return ComicLayoutDetection.fromRatios(ratios.whereType<double>());
  }

  Future<double?> _readRatio(
    String image,
    String? sourceKey,
    String comicId,
    String chapterId,
  ) async {
    if (_cancelled) return null;
    StreamIterator<ImageDownloadProgress>? reader;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    try {
      Uint8List? bytes;
      if (image.startsWith('file://')) {
        bytes = await File(image).readAsBytes();
      } else {
        reader = StreamIterator(
          ImageDownloader.loadComicImage(image, sourceKey, comicId, chapterId),
        );
        _readers.add(reader);
        final iterator = reader;
        Future<Uint8List?> readBytes() async {
          while (!_cancelled && await iterator.moveNext()) {
            final bytes = iterator.current.imageBytes;
            if (bytes != null) return bytes;
          }
          return null;
        }

        bytes = await readBytes().timeout(const Duration(seconds: 8));
      }
      if (_cancelled || bytes == null || bytes.isEmpty) return null;
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (_cancelled || descriptor.width <= 0 || descriptor.height <= 0) {
        return null;
      }
      return descriptor.height / descriptor.width;
    } catch (_) {
      // A failed sample must never prevent the comic itself from opening.
      return null;
    } finally {
      descriptor?.dispose();
      buffer?.dispose();
      if (reader != null) {
        _readers.remove(reader);
        await reader.cancel();
      }
    }
  }
}
