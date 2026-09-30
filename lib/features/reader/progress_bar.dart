import 'package:flutter/material.dart';
import 'package:venera_next/components/custom_slider.dart';
import 'package:venera_next/components/effects.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/widget_utils.dart';

/// Presentation for progress and actions. The shell supplies navigation policy.
class ReaderBottomBar extends StatelessWidget {
  const ReaderBottomBar({
    super.key,
    required this.label,
    required this.actions,
    required this.page,
    required this.maxPage,
    required this.reversed,
    required this.isOpen,
    required this.onPageChanged,
    required this.onPrevious,
    required this.onNext,
  });
  static const height = 105.0;
  final String label;
  final List<Widget> actions;
  final int page;
  final int maxPage;
  final bool reversed;
  final bool isOpen;
  final ValueChanged<int> onPageChanged;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    Widget child = SizedBox(
      height: height,
      child: Column(
        children: [
          const SizedBox(height: 8),
          Row(
            children: [
              const SizedBox(width: 8),
              IconButton.filledTonal(
                onPressed: onPrevious,
                icon: const Icon(Icons.first_page),
              ),
              Expanded(
                child: ReaderProgressSlider(
                  page: page,
                  maxPage: maxPage,
                  reversed: reversed,
                  onChanged: onPageChanged,
                ),
              ),
              IconButton.filledTonal(
                onPressed: onNext,
                icon: const Icon(Icons.last_page),
              ),
              const SizedBox(width: 8),
            ],
          ),
          LayoutBuilder(
            builder: (context, constrains) {
              final small = (constrains.maxWidth - actions.length * 50) < 120;
              return Row(
                children: [
                  if (!small) ...[
                    Container(
                      height: 24,
                      padding: const EdgeInsets.fromLTRB(6, 2, 6, 0),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.tertiaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(child: Text(label)),
                    ).paddingLeft(16),
                    const Spacer(),
                    for (var button in actions) button.paddingHorizontal(4),
                    const SizedBox(width: 4),
                  ] else
                    for (var button in actions)
                      Expanded(child: Center(child: button)),
                ],
              );
            },
          ),
        ],
      ),
    );

    return BlurEffect(
      child: Container(
        decoration: BoxDecoration(
          color: context.colorScheme.surface.toOpacity(0.92),
          border: isOpen
              ? Border(
                  top: BorderSide(
                    color: Colors.grey.toOpacity(0.5),
                    width: 0.5,
                  ),
                )
              : null,
        ),
        padding: EdgeInsets.only(bottom: context.padding.bottom),
        child: Padding(
          padding: EdgeInsets.only(
            left: context.padding.left,
            right: context.padding.right,
          ),
          child: child,
        ),
      ),
    );
  }
}

class ReaderProgressSlider extends StatefulWidget {
  const ReaderProgressSlider({
    super.key,
    required this.page,
    required this.maxPage,
    required this.reversed,
    required this.onChanged,
  });
  final int page;
  final int maxPage;
  final bool reversed;
  final ValueChanged<int> onChanged;
  @override
  State<ReaderProgressSlider> createState() => _ReaderProgressSliderState();
}

class _ReaderProgressSliderState extends State<ReaderProgressSlider> {
  final _focus = FocusNode(canRequestFocus: false);
  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (_focus.hasFocus) _focus.nextFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final displayPage = widget.page.clamp(1, widget.maxPage);
    return CustomSlider(
      focusNode: _focus,
      value: displayPage.toDouble(),
      min: 1,
      max: widget.maxPage.clamp(displayPage, 1 << 16).toDouble(),
      reversed: widget.reversed,
      divisions: (widget.maxPage - 1).clamp(2, 1 << 16),
      onChanged: (value) => widget.onChanged(value.toInt()),
    );
  }
}

class ReaderPageInfo extends StatelessWidget {
  const ReaderPageInfo({super.key, required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Text(
        text,
        style: TextStyle(
          fontSize: 14,
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4
            ..color = context.colorScheme.onInverseSurface,
        ),
      ),
      Text(text),
    ],
  );
}
