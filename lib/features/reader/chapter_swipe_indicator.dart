import 'package:flutter/material.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

const double chapterSwipeThreshold = 160;

class ChapterSwipeIndicator extends StatelessWidget {
  const ChapterSwipeIndicator({
    super.key,
    this.controller,
    required this.isPrev,
  });

  final ScrollController? controller;

  final bool isPrev;

  double get _progress {
    final positions = controller?.positions;
    if (positions == null || positions.length != 1) return 0;
    final position = positions.single;
    if (!position.hasPixels || !position.hasContentDimensions) return 0;
    final offset = isPrev
        ? position.minScrollExtent - position.pixels
        : position.pixels - position.maxScrollExtent;
    return offset.isFinite
        ? (offset / chapterSwipeThreshold).clamp(0.0, 1.0)
        : 0;
  }

  @override
  Widget build(BuildContext context) {
    final scroll = controller;
    if (scroll == null) return _buildIndicator(context);
    // Flutter owns this subscription; the scroll controller belongs to the view.
    return ListenableBuilder(
      listenable: scroll,
      builder: (context, _) => _buildIndicator(context),
    );
  }

  Widget _buildIndicator(BuildContext context) {
    final msg = isPrev
        ? "Swipe down for previous chapter".tl
        : "Swipe up for next chapter".tl;

    return CustomPaint(
      painter: _ProgressPainter(
        value: _progress,
        backgroundColor: context.colorScheme.surfaceContainerLow,
        color: context.colorScheme.surfaceContainerHighest,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isPrev ? Icons.arrow_downward : Icons.arrow_upward,
            color: context.colorScheme.onSurface,
            size: 16,
          ),
          const SizedBox(width: 4),
          Flexible(child: Text(msg)),
        ],
      ).paddingVertical(6).paddingHorizontal(16),
    );
  }
}

class _ProgressPainter extends CustomPainter {
  final double value;

  final Color backgroundColor;

  final Color color;

  const _ProgressPainter({
    required this.value,
    required this.backgroundColor,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromLTRBR(0, 0, size.width, size.height, Radius.circular(16)),
      paint,
    );

    paint.color = color;
    canvas.drawRRect(
      RRect.fromLTRBR(
        0,
        0,
        size.width * value,
        size.height,
        Radius.circular(16),
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return oldDelegate is! _ProgressPainter ||
        oldDelegate.value != value ||
        oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.color != color;
  }
}
