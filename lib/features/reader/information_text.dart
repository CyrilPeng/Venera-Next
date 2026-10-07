import 'package:flutter/material.dart';

/// Outlined reader information with one accessible text and bounded layout.
class ReaderInformationText extends StatelessWidget {
  const ReaderInformationText({
    super.key,
    required this.text,
    this.maxLines = 1,
  });
  final String text;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.copyWith(fontSize: 14);
    final overflow = maxLines == null
        ? TextOverflow.clip
        : TextOverflow.ellipsis;
    return Stack(
      children: [
        ExcludeSemantics(
          child: Text(
            text,
            maxLines: maxLines,
            overflow: overflow,
            style: style.copyWith(
              foreground: Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.4
                ..color = Theme.of(context).colorScheme.onInverseSurface,
            ),
          ),
        ),
        Text(text, maxLines: maxLines, overflow: overflow, style: style),
      ],
    );
  }
}
