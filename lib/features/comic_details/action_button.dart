import 'package:flutter/material.dart';
import 'package:venera_next/components/gesture.dart';
import 'package:venera_next/foundation/app.dart';

class ComicDetailActionButton extends StatelessWidget {
  const ComicDetailActionButton({
    super.key,
    required this.icon,
    required this.text,
    required this.onPressed,
    this.onLongPressed,
    this.activeIcon,
    this.isActive,
    this.isLoading,
    this.iconColor,
  });

  final Widget icon;

  final Widget? activeIcon;

  final bool? isActive;

  final String text;

  final void Function() onPressed;

  final bool? isLoading;

  final Color? iconColor;

  final void Function()? onLongPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: context.colorScheme.outlineVariant,
          width: 0.6,
        ),
      ),
      child: ClickInkWell(
        onTap: () {
          if (!(isLoading ?? false)) {
            onPressed();
          }
        },
        onLongPress: onLongPressed,
        borderRadius: BorderRadius.circular(18),
        child: IconTheme.merge(
          data: IconThemeData(size: 20, color: iconColor),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isLoading ?? false)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 1.8),
                )
              else
                (isActive ?? false) ? (activeIcon ?? icon) : icon,
              const SizedBox(width: 8),
              Text(text),
            ],
          ).paddingHorizontal(16),
        ),
      ),
    );
  }
}
