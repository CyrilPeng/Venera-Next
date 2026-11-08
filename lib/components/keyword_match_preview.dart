import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:venera_next/foundation/keyword_rule.dart';

/// Shared by the trial field and hidden reasons, so they highlight the same
/// original-text offsets as production matching. Long descriptions show the hit.
class KeywordMatchPreview extends StatelessWidget {
  const KeywordMatchPreview({super.key, required this.match});
  final KeywordMatch match;

  @override
  Widget build(BuildContext context) {
    final text = match.text;
    var start = math.max(0, match.start - 48);
    var end = math.min(text.length, match.end + 48);
    if (start > 0 && _lowSurrogate(text.codeUnitAt(start))) start--;
    if (end < text.length && _lowSurrogate(text.codeUnitAt(end))) end++;
    final colors = Theme.of(context).colorScheme;
    return Text.rich(
      TextSpan(
        children: [
          if (start > 0) const TextSpan(text: '…'),
          TextSpan(text: text.substring(start, match.start)),
          TextSpan(
            text: text.substring(match.start, match.end),
            style: TextStyle(
              fontWeight: FontWeight.bold,
              backgroundColor: colors.primaryContainer,
              color: colors.onPrimaryContainer,
            ),
          ),
          TextSpan(text: text.substring(match.end, end)),
          if (end < text.length) const TextSpan(text: '…'),
        ],
      ),
      maxLines: 6,
      overflow: TextOverflow.ellipsis,
    );
  }

  bool _lowSurrogate(int value) => value >= 0xdc00 && value <= 0xdfff;
}
