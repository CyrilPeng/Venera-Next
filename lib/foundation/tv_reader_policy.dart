import 'dart:math' as math;

import 'preferences.dart';

/// Experimental device-local limits, not a claim about total process memory.
abstract final class TvReaderPolicy {
  static const lowMemory = BoolPreference('tvLowMemoryMode', true);
  static const cacheBytes = 64 << 20;
  static const decodePixels = 1920 * 1080;
  static const maximumEdge = 8192;

  static ({int width, int height}) decodeSize(
    int width,
    int height, {
    required int pixelBudget,
  }) {
    if (pixelBudget <= 0) throw ArgumentError.value(pixelBudget, 'pixelBudget');
    if (width <= 0 || height <= 0) return (width: width, height: height);
    final scale = math.min(
      1.0,
      math.min(
        math.sqrt(pixelBudget / (width.toDouble() * height)),
        maximumEdge / math.max(width, height),
      ),
    );
    var targetWidth = math.max(1, (width * scale).floor());
    var targetHeight = math.max(1, (height * scale).floor());
    // Rounding a very thin strip up to one pixel must not exceed the budget.
    if (targetWidth * targetHeight > pixelBudget) {
      if (targetWidth >= targetHeight) {
        targetWidth = math.max(1, pixelBudget ~/ targetHeight);
      } else {
        targetHeight = math.max(1, pixelBudget ~/ targetWidth);
      }
    }
    return (width: targetWidth, height: targetHeight);
  }
}
