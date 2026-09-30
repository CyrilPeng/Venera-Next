import 'package:flutter/material.dart';
import 'package:venera_next/foundation/translations.dart';

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

class ReaderBrightnessOverlay extends StatelessWidget {
  const ReaderBrightnessOverlay({
    super.key,
    required this.enabled,
    required this.brightness,
  });

  final bool enabled;
  final Object? brightness;

  @override
  Widget build(BuildContext context) {
    final opacity = readerBrightnessOverlayOpacity(
      enabled: enabled,
      brightness: brightness,
    );
    if (opacity == 0) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: SizedBox.expand(
        child: ColoredBox(color: Colors.black.withValues(alpha: opacity)),
      ),
    );
  }
}

class ReaderBrightnessControl extends StatelessWidget {
  const ReaderBrightnessControl({
    super.key,
    required this.enabled,
    required this.brightness,
    required this.onEnabledChanged,
    required this.onBrightnessChanged,
    this.onBrightnessChangeEnd,
    this.compact = false,
  });

  final bool enabled;
  final Object? brightness;
  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<int> onBrightnessChanged;
  final ValueChanged<int>? onBrightnessChangeEnd;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final normalizedBrightness = normalizeReaderBrightness(brightness);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SwitchListTile(
          contentPadding: compact ? EdgeInsets.zero : null,
          title: Text('Night dimming'.tl),
          value: enabled,
          onChanged: onEnabledChanged,
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          child: enabled
              ? ListTile(
                  contentPadding: compact ? EdgeInsets.zero : null,
                  title: Text('Reader brightness'.tl),
                  trailing: Text('$normalizedBrightness%'),
                  subtitle: Row(
                    children: [
                      const Icon(Icons.brightness_low, size: 20),
                      Expanded(
                        child: Slider(
                          min: readerBrightnessMin.toDouble(),
                          max: readerBrightnessMax.toDouble(),
                          divisions:
                              (readerBrightnessMax - readerBrightnessMin) ~/ 5,
                          value: normalizedBrightness.toDouble(),
                          onChanged: (value) {
                            onBrightnessChanged(value.round());
                          },
                          onChangeEnd: (value) {
                            onBrightnessChangeEnd?.call(value.round());
                          },
                        ),
                      ),
                      const Icon(Icons.brightness_high, size: 20),
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// Compact settings panel; persistence and preference scope belong to its host.
class ReaderBrightnessPanel extends StatelessWidget {
  const ReaderBrightnessPanel({
    super.key,
    required this.enabled,
    required this.brightness,
    required this.onEnabledChanged,
    required this.onBrightnessChanged,
    required this.onBrightnessChangeEnd,
  });
  final bool enabled;
  final Object? brightness;
  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<int> onBrightnessChanged;
  final ValueChanged<int> onBrightnessChangeEnd;
  @override
  Widget build(BuildContext context) {
    final panelWidth =
        (MediaQuery.sizeOf(context).width -
                MediaQuery.paddingOf(context).left -
                MediaQuery.paddingOf(context).right -
                32)
            .clamp(0.0, 360.0);
    return Material(
      elevation: 8,
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: panelWidth,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: ReaderBrightnessControl(
            compact: true,
            enabled: enabled,
            brightness: brightness,
            onEnabledChanged: onEnabledChanged,
            onBrightnessChanged: onBrightnessChanged,
            onBrightnessChangeEnd: onBrightnessChangeEnd,
          ),
        ),
      ),
    );
  }
}
