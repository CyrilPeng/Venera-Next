const int readerBrightnessMin = 20;
const int readerBrightnessMax = 100;
const int defaultReaderBrightness = 50;

int normalizeReaderBrightness(Object? value) {
  final brightness = value is num ? value.round() : defaultReaderBrightness;
  return brightness.clamp(readerBrightnessMin, readerBrightnessMax);
}

double readerBrightnessOverlayOpacity({
  required bool enabled,
  required Object? brightness,
}) {
  if (!enabled) {
    return 0;
  }
  return 1 - normalizeReaderBrightness(brightness) / readerBrightnessMax;
}
