import 'dart:ui';

/// The persisted bounds and maximized state of one desktop window.
class WindowPlacement {
  const WindowPlacement(this.rect, this.isMaximized);

  factory WindowPlacement.fromJson(Map<String, dynamic> json) =>
      WindowPlacement(
        Rect.fromLTWH(
          (json['x'] as num).toDouble(),
          (json['y'] as num).toDouble(),
          (json['width'] as num).toDouble(),
          (json['height'] as num).toDouble(),
        ),
        json['isMaximized'] as bool,
      );

  final Rect rect;
  final bool isMaximized;

  static const defaultPlacement = WindowPlacement(
    Rect.fromLTWH(10, 10, 900, 600),
    false,
  );

  /// Preserve the existing fallback policy for invalid native bounds.
  static bool validate(Rect rect) => rect.left >= 0 && rect.top >= 0;

  Map<String, Object> toJson() => {
    'width': rect.width,
    'height': rect.height,
    'x': rect.left,
    'y': rect.top,
    'isMaximized': isMaximized,
  };

  @override
  bool operator ==(Object other) =>
      other is WindowPlacement &&
      other.rect == rect &&
      other.isMaximized == isMaximized;

  @override
  int get hashCode => Object.hash(rect, isMaximized);
}
