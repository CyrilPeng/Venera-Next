import 'package:flutter/material.dart';
import 'package:venera_next/foundation/translations.dart';
import 'chapter_navigation.dart';

/// Keeps only the last glyph for the exit animation. Hidden actions have no
/// pointer, keyboard or accessibility target, including during that animation.
class ReaderChapterNavigationButton extends StatefulWidget {
  const ReaderChapterNavigationButton({super.key, required this.action});
  final ReaderChapterNavigationAction? action;
  @override
  State<ReaderChapterNavigationButton> createState() =>
      _ReaderChapterNavigationButtonState();
}

class _ReaderChapterNavigationButtonState
    extends State<ReaderChapterNavigationButton> {
  bool _pointsLeft = false;
  @override
  Widget build(BuildContext context) {
    final action = widget.action;
    final visible = action?.isCurrent == true;
    if (visible) _pointsLeft = (action!.direction == -1) != action.reversed;
    final colors = Theme.of(context).colorScheme;
    return AnimatedPositioned(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 180),
      right: 16 + MediaQuery.paddingOf(context).right,
      bottom: visible ? 36 + MediaQuery.paddingOf(context).bottom : -58,
      child: IgnorePointer(
        ignoring: !visible,
        child: ExcludeFocus(
          excluding: !visible,
          child: ExcludeSemantics(
            excluding: !visible,
            child: SizedBox.square(
              dimension: 58,
              child: Material(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(16),
                elevation: visible ? 2 : 0,
                child: IconButton(
                  style: IconButton.styleFrom(
                    minimumSize: const Size.square(58),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    foregroundColor: colors.onPrimaryContainer,
                  ),
                  tooltip:
                      (action?.direction == -1
                              ? 'Previous chapter'
                              : 'Next chapter')
                          .tl,
                  onPressed: visible ? action!.select : null,
                  icon: Icon(
                    _pointsLeft
                        ? Icons.arrow_back_ios_outlined
                        : Icons.arrow_forward_ios,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
