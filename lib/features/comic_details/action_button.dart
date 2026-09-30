import 'package:flutter/material.dart';
import 'package:venera_next/components/gesture.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/widget_utils.dart';

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
    final enabled = !(isLoading ?? false);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Semantics(
        button: true,
        enabled: enabled,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: ClickInkWell(
            onTap: enabled ? onPressed : null,
            onLongPress: enabled ? onLongPressed : null,
            mouseCursor: enabled
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            borderRadius: BorderRadius.circular(18),
            // Keep the compact outline inside the full-height touch target.
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: context.colorScheme.outlineVariant,
                  width: 0.6,
                ),
              ),
              child: IconTheme.merge(
                data: IconThemeData(size: 20, color: iconColor),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!enabled)
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
          ),
        ),
      ),
    );
  }
}
