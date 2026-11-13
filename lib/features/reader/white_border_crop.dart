import 'dart:async';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/foundation/log.dart';

/// Only complete near-white columns qualify. A single dark/text pixel stops
/// that edge; a blank page and margins wider than a quarter remain untouched.
(int, int) horizontalWhiteBorderInsets(Uint8List rgba, int width, int height) {
  if (width < 32 || height < 1 || rgba.length != width * height * 4) {
    return (0, 0);
  }
  final maximum = width ~/ 4;
  var left = maximum + 1, right = maximum + 1;
  bool white(int x, int y) {
    final offset = (y * width + x) * 4;
    if (rgba[offset + 3] == 0) return true;
    return rgba[offset + 3] == 255 &&
        rgba[offset] >= 253 &&
        rgba[offset + 1] >= 253 &&
        rgba[offset + 2] >= 253;
  }

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < left; x++) {
      if (!white(x, y)) {
        left = x;
        break;
      }
    }
    for (var x = 0; x < right; x++) {
      if (!white(width - x - 1, y)) {
        right = x;
        break;
      }
    }
    if (left == 0 && right == 0) break;
  }
  final padding = (width * 0.002).ceil().clamp(2, maximum);
  final minimum = (width * 0.01).ceil().clamp(4, maximum);
  int keep(int inset) =>
      inset > maximum || inset < minimum ? 0 : inset - padding;
  return (keep(left), keep(right));
}

typedef _Scan = ({TransferableTypedData pixels, int width, int height});

(int, int) _scan(_Scan input) => horizontalWhiteBorderInsets(
  input.pixels.materialize().asUint8List(),
  input.width,
  input.height,
);

/// A bounded rectangle cache for one continuous-reader session. Source pixels
/// are retained only while a scan runs; queued scans and exit holds are owned
/// by the existing ImageWork drain. Decoding/download cache keys never change.
class ReaderWhiteBorderCrop extends ChangeNotifier {
  ReaderWhiteBorderCrop(this.work) {
    _removeResume = work.addResumeListener(() {
      _retryRevision++;
      notifyListeners();
    });
  }

  final ImageWork work;
  static const pixelLimit = 8 * 1024 * 1024;
  static const pendingLimit = 4;
  final _cache = <(Object, int, int), ui.Rect>{};
  final _pending = <(Object, int, int), Future<ui.Rect?>>{};
  final _tasks = <ImageWorkTask>{};
  Future<void> _tail = Future.value();
  late final VoidCallback _removeResume;
  bool _disposed = false;
  bool _waitingForSlot = false;
  int _retryRevision = 0;

  /// A declined/cancelled scan can retry after a slot or admission returns,
  /// including when the notification precedes its pending completion.
  int get retryRevision => _retryRevision;

  Future<ui.Rect?> detect(ui.Image image, Object identity) {
    if (_disposed) return Future.value();
    final key = (identity, image.width, image.height);
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return SynchronousFuture(cached);
    }
    if (_pending.containsKey(key)) return _pending[key]!;
    final full = ui.Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    if (image.width * image.height > pixelLimit) {
      _remember(key, full);
      return SynchronousFuture(full);
    }
    if (_tasks.length >= pendingLimit) {
      _waitingForSlot = true;
      return Future.value();
    }
    final task = work.start();
    if (task == null) return Future.value();
    _tasks.add(task);
    late final ui.Image retained;
    try {
      retained = image.clone();
    } catch (error) {
      _tasks.remove(task);
      task.finish();
      Log.warning('Reader crop', 'Image retention failed: $error');
      return SynchronousFuture(full);
    }
    final previous = _tail;
    final completion = Completer<ui.Rect?>();
    _pending[key] = completion.future;
    // Serialize pixel readback and worker scans to bound temporary RGBA memory.
    _tail = () async {
      ui.Rect? result;
      try {
        await previous;
        task.check();
        final bytes = await retained.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        );
        task.check();
        if (bytes == null) throw StateError('Image pixels are unavailable');
        final (left, right) = await compute(_scan, (
          pixels: TransferableTypedData.fromList([
            bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
          ]),
          width: key.$2,
          height: key.$3,
        ));
        task.check();
        result = ui.Rect.fromLTRB(
          left.toDouble(),
          0,
          (key.$2 - right).toDouble(),
          key.$3.toDouble(),
        );
      } on ImageWorkTaskCancelled {
        // A reversible hold can retry once admission resumes.
      } catch (error) {
        Log.warning('Reader crop', 'White border detection failed: $error');
        result = full;
      } finally {
        try {
          retained.dispose();
        } catch (error, stack) {
          task.recordFailure(error, stack);
        }
        _tasks.remove(task);
        task.finish();
        _pending.remove(key);
        if (result != null && !_disposed && !task.isCancelled) {
          _remember(key, result);
          completion.complete(result);
        } else {
          completion.complete();
        }
        if (_waitingForSlot && !_disposed) {
          _waitingForSlot = false;
          _retryRevision++;
          notifyListeners();
        }
      }
    }();
    return completion.future;
  }

  void _remember((Object, int, int) key, ui.Rect result) {
    _cache[key] = result;
    if (_cache.length > 128) _cache.remove(_cache.keys.first);
  }

  @override
  void dispose() {
    _disposed = true;
    _removeResume();
    for (final task in _tasks.toList()) {
      task.cancel();
    }
    _cache.clear();
    super.dispose();
  }
}
