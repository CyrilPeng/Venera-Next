import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera_next/foundation/app_profile.dart';

/// TV input is selected by the build, never by screen width or Android alone.
class TvNavigation extends StatelessWidget {
  const TvNavigation({
    super.key,
    required this.child,
    this.enabled,
    this.onBack,
  });

  final Widget child;
  final bool? enabled;
  final VoidCallback? onBack;

  static bool enabledOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_TvMode>()?.enabled ??
      AppProfile.current.isTv;

  @override
  Widget build(BuildContext context) {
    final active = enabled ?? AppProfile.current.isTv;
    if (!active) return child;
    final media = MediaQuery.of(context);
    EdgeInsets safeInsets(EdgeInsets insets) => EdgeInsets.fromLTRB(
      math.max(insets.left, 24),
      math.max(insets.top, 24),
      math.max(insets.right, 24),
      math.max(insets.bottom, 24),
    );
    return _TvMode(
      enabled: true,
      child: MediaQuery(
        data: media.copyWith(
          navigationMode: NavigationMode.directional,
          textScaler: media.textScaler.clamp(minScaleFactor: 1.1),
          padding: safeInsets(media.padding),
          viewPadding: safeInsets(media.viewPadding),
        ),
        child: Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.select, includeRepeats: false):
                ActivateIntent(),
            SingleActivator(
              LogicalKeyboardKey.gameButtonA,
              includeRepeats: false,
            ): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.arrowLeft):
                DirectionalFocusIntent(TraversalDirection.left),
            SingleActivator(LogicalKeyboardKey.arrowRight):
                DirectionalFocusIntent(TraversalDirection.right),
            SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(
              TraversalDirection.up,
            ),
            SingleActivator(LogicalKeyboardKey.arrowDown):
                DirectionalFocusIntent(TraversalDirection.down),
          },
          child: CallbackShortcuts(
            bindings: {
              if (onBack != null)
                for (final key in [
                  LogicalKeyboardKey.escape,
                  LogicalKeyboardKey.goBack,
                  LogicalKeyboardKey.gameButtonB,
                ])
                  SingleActivator(key, includeRepeats: false): onBack!,
            },
            child: FocusTraversalGroup(
              policy: ReadingOrderTraversalPolicy(),
              child: Focus(
                canRequestFocus: false,
                skipTraversal: true,
                onKeyEvent: (_, event) =>
                    event is KeyRepeatEvent &&
                        const [
                          LogicalKeyboardKey.select,
                          LogicalKeyboardKey.gameButtonA,
                          LogicalKeyboardKey.enter,
                          LogicalKeyboardKey.numpadEnter,
                        ].contains(event.logicalKey)
                    ? KeyEventResult.handled
                    : KeyEventResult.ignored,
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TvMode extends InheritedWidget {
  const _TvMode({required this.enabled, required super.child});
  final bool enabled;

  @override
  bool updateShouldNotify(_TvMode oldWidget) => enabled != oldWidget.enabled;
}

/// Paints outside a control's content without adding another traversal target.
class TvFocusOutline extends StatefulWidget {
  const TvFocusOutline({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
    this.onMenu,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final VoidCallback? onMenu;

  @override
  State<TvFocusOutline> createState() => _TvFocusOutlineState();
}

class _TvFocusOutlineState extends State<TvFocusOutline> {
  bool _focused = false;

  void _focusChanged(bool focused) {
    if (_focused == focused) return;
    setState(() => _focused = focused);
    if (!focused) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_focused) return;
      unawaited(
        Scrollable.ensureVisible(
          context,
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 120),
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!TvNavigation.enabledOf(context)) return widget.child;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: _focusChanged,
      onKeyEvent: (_, event) {
        if (widget.onMenu != null &&
            (event.logicalKey == LogicalKeyboardKey.contextMenu ||
                event.logicalKey == LogicalKeyboardKey.gameButtonX)) {
          if (event is KeyDownEvent) widget.onMenu!();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: widget.borderRadius,
          border: _focused
              ? Border.all(
                  color: Theme.of(context).colorScheme.primary,
                  width: 3,
                )
              : null,
        ),
        child: widget.child,
      ),
    );
  }
}

/// Adds remote activation to existing gesture-only controls on TV builds.
class TvFocusable extends StatelessWidget {
  const TvFocusable({
    super.key,
    required this.child,
    required this.onPressed,
    this.autofocus = false,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
  });

  final Widget child;
  final VoidCallback? onPressed;
  final bool autofocus;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    if (!TvNavigation.enabledOf(context)) return child;
    return TvFocusOutline(
      borderRadius: borderRadius,
      child: Semantics(
        button: true,
        enabled: onPressed != null,
        child: FocusableActionDetector(
          enabled: onPressed != null,
          autofocus: autofocus,
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                onPressed?.call();
                return null;
              },
            ),
          },
          child: child,
        ),
      ),
    );
  }
}
