import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:venera_next/foundation/app.dart';

import 'consts.dart';

class ClickInkWell extends InkWell {
  const ClickInkWell({
    super.key,
    super.child,
    super.onTap,
    super.onDoubleTap,
    super.onLongPress,
    super.onTapDown,
    super.onTapUp,
    super.onTapCancel,
    super.onSecondaryTapDown,
    super.onSecondaryTapUp,
    super.onSecondaryTapCancel,
    super.onHighlightChanged,
    super.onHover,
    MouseCursor mouseCursor = SystemMouseCursors.click,
    super.focusNode,
    super.autofocus,
    super.canRequestFocus,
    super.focusColor,
    super.hoverColor,
    super.highlightColor,
    super.overlayColor,
    super.splashColor,
    super.splashFactory,
    super.radius,
    super.borderRadius,
    super.customBorder,
    super.enableFeedback,
    super.excludeFromSemantics,
  }) : super(mouseCursor: mouseCursor);
}

class MouseBackDetector extends StatelessWidget {
  const MouseBackDetector({
    super.key,
    required this.onTapDown,
    required this.child,
  });

  final Widget child;

  final void Function() onTapDown;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (event) {
        if (event.buttons == kBackMouseButton) {
          onTapDown();
        }
      },
      behavior: HitTestBehavior.translucent,
      child: child,
    );
  }
}

class AnimatedTapRegion extends StatefulWidget {
  const AnimatedTapRegion({
    super.key,
    required this.child,
    required this.onTap,
    this.borderRadius = 0,
  });

  final Widget child;

  final void Function() onTap;

  final double borderRadius;

  @override
  State<AnimatedTapRegion> createState() => _AnimatedTapRegionState();
}

class _AnimatedTapRegionState extends State<AnimatedTapRegion> {
  bool isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) {
        setState(() {
          isHovered = true;
        });
      },
      onExit: (_) {
        setState(() {
          isHovered = false;
        });
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedPhysicalModel(
          duration: fastAnimationDuration,
          elevation: isHovered ? 3 : 1,
          color: context.colorScheme.surface,
          shadowColor: context.colorScheme.shadow,
          borderRadius: BorderRadius.circular(widget.borderRadius),
          child: widget.child,
        ),
      ),
    );
  }
}
