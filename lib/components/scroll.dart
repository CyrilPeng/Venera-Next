import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/widget_utils.dart';

import 'consts.dart';

class SmoothCustomScrollView extends StatelessWidget {
  const SmoothCustomScrollView({
    super.key,
    required this.slivers,
    this.controller,
  });

  final ScrollController? controller;

  final List<Widget> slivers;

  @override
  Widget build(BuildContext context) {
    return SmoothScrollProvider(
      controller: controller,
      builder: (context, controller, physics) {
        return CustomScrollView(
          controller: controller,
          physics: physics,
          slivers: [
            ...slivers,
            SliverPadding(
              padding: EdgeInsets.only(bottom: context.padding.bottom),
            ),
          ],
        );
      },
    );
  }
}

class SmoothScrollProvider extends StatefulWidget {
  const SmoothScrollProvider({
    super.key,
    this.controller,
    required this.builder,
  });

  final ScrollController? controller;

  final Widget Function(BuildContext, ScrollController, ScrollPhysics) builder;

  @override
  State<SmoothScrollProvider> createState() => _SmoothScrollProviderState();
}

class _SmoothScrollProviderState extends State<SmoothScrollProvider> {
  late ScrollController _controller;
  late bool _ownsController;

  double? _futurePosition;
  ScrollPosition? _wheelPosition;
  int _wheelGeneration = 0;

  static bool _isMouseScroll = App.isDesktop;

  late int id;

  static int _id = 0;

  var activeChildren = <int>{};

  ScrollState? parent;
  bool _hovered = false;

  @override
  void initState() {
    _controller = widget.controller ?? ScrollController();
    _ownsController = widget.controller == null;
    super.initState();
    id = _id;
    _id++;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = ScrollState.maybeOf(context);
    if (!identical(parent, next)) {
      parent?.onChildInactive(id);
      parent = next;
      if (_hovered) parent?.onChildActive(id);
    }
  }

  @override
  void didUpdateWidget(covariant SmoothScrollProvider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      final previous = _controller;
      final owned = _ownsController;
      _controller = widget.controller ?? ScrollController();
      _ownsController = widget.controller == null;
      _resetWheel();
      if (owned && !identical(previous, _controller)) previous.dispose();
    }
  }

  @override
  void deactivate() {
    parent?.onChildInactive(id);
    parent = null;
    _resetWheel();
    super.deactivate();
  }

  @override
  void dispose() {
    parent?.onChildInactive(id);
    _resetWheel();
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  void _resetWheel() {
    _wheelGeneration++;
    _futurePosition = null;
    _wheelPosition = null;
  }

  void _onChildActive(int child) => activeChildren.add(child);
  void _onChildInactive(int child) => activeChildren.remove(child);

  void _onPointerSignal(PointerSignalEvent event) {
    if (activeChildren.isNotEmpty ||
        event is! PointerScrollEvent ||
        HardwareKeyboard.instance.isShiftPressed) {
      return;
    }
    if (event.kind == PointerDeviceKind.mouse && !_isMouseScroll) {
      setState(() => _isMouseScroll = true);
    }
    if (!_isMouseScroll || _controller.positions.length != 1) return;
    final controller = _controller;
    final position = controller.position;
    if (!position.hasPixels || !position.hasContentDimensions) return;
    if (!identical(_wheelPosition, position)) {
      _resetWheel();
      _wheelPosition = position;
    }
    final current = position.pixels;
    final old = _futurePosition;
    _futurePosition ??= current;
    final acceleration = (_futurePosition! - current).abs() / 1600 + 1;
    _futurePosition = _futurePosition! + event.scrollDelta.dy * acceleration;
    final before = (_futurePosition! - current).abs();
    _futurePosition = _futurePosition!.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    final after = (_futurePosition! - current).abs();
    if (_futurePosition == old) return;
    final target = _futurePosition!;
    var duration = fastAnimationDuration;
    if (after < before) {
      duration = duration * (after / before);
      if (duration < const Duration(milliseconds: 10)) {
        duration = const Duration(milliseconds: 10);
      }
    }
    final generation = ++_wheelGeneration;
    controller.animateTo(target, duration: duration, curve: Curves.linear).then(
      (_) {
        // The controller may survive while its original ScrollPosition does
        // not. A completion belongs to both the original viewport and input.
        if (!mounted ||
            generation != _wheelGeneration ||
            !identical(_controller, controller) ||
            controller.positions.length != 1 ||
            !identical(controller.position, position)) {
          return;
        }
        if (position.pixels == target && target == _futurePosition) {
          _resetWheel();
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (App.isMacOS) {
      return widget.builder(
        context,
        _controller,
        const BouncingScrollPhysics(),
      );
    }
    var child = Listener(
      onPointerDown: (event) {
        _resetWheel();
        if (_isMouseScroll) {
          setState(() {
            _isMouseScroll = false;
          });
        }
      },
      onPointerSignal: _onPointerSignal,
      child: ScrollState._(
        controller: _controller,
        onChildActive: _onChildActive,
        onChildInactive: _onChildInactive,
        child: widget.builder(
          context,
          _controller,
          _isMouseScroll
              ? const NeverScrollableScrollPhysics()
              : const BouncingScrollPhysics(),
        ),
      ),
    );

    return MouseRegion(
      onEnter: (_) {
        _hovered = true;
        parent?.onChildActive(id);
      },
      onExit: (_) {
        _hovered = false;
        parent?.onChildInactive(id);
      },
      child: child,
    );
  }
}

class ScrollState extends InheritedWidget {
  const ScrollState._({
    required this.controller,
    required super.child,
    required this.onChildActive,
    required this.onChildInactive,
  });

  final ScrollController controller;

  final void Function(int id) onChildActive;

  final void Function(int id) onChildInactive;

  static ScrollState of(BuildContext context) {
    final ScrollState? provider = context
        .dependOnInheritedWidgetOfExactType<ScrollState>();
    return provider!;
  }

  static ScrollState? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<ScrollState>();
  }

  @override
  bool updateShouldNotify(ScrollState oldWidget) {
    return oldWidget.controller != controller ||
        oldWidget.onChildActive != onChildActive ||
        oldWidget.onChildInactive != onChildInactive;
  }
}

class AppScrollBar extends StatefulWidget {
  const AppScrollBar({
    super.key,
    required this.controller,
    required this.child,
    this.topPadding = 0,
  });

  final ScrollController controller;

  final Widget child;

  final double topPadding;

  @override
  State<AppScrollBar> createState() => _AppScrollBarState();
}

class _AppScrollBarState extends State<AppScrollBar> {
  ScrollController get _scrollController => widget.controller;
  ScrollPosition? _observedPosition;
  ScrollPosition? _dragPosition;
  bool _disposed = false;
  bool _syncScheduled = false;

  double minExtent = 0;
  double maxExtent = 0;
  double position = 0;

  double viewHeight = 0;

  final _scrollIndicatorSize = App.isDesktop ? 36.0 : 54.0;

  late final VerticalDragGestureRecognizer _dragGestureRecognizer;

  bool _isVisible = false;
  Timer? _hideTimer;
  static const _hideDuration = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(onChanged);
    _dragGestureRecognizer = VerticalDragGestureRecognizer()
      ..onUpdate = onUpdate
      ..onStart = (_) {
        _dragPosition = _position;
        _showScrollbar();
      }
      ..onEnd = (_) {
        _dragPosition = null;
        _scheduleHide();
      }
      ..onCancel = () => _dragPosition = null;
  }

  @override
  void didUpdateWidget(covariant AppScrollBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(onChanged);
      _scrollController.addListener(onChanged);
      _dragPosition = null;
      _observedPosition = null;
      minExtent = maxExtent = position = 0;
      _hideTimer?.cancel();
      _isVisible = false;
    }
  }

  @override
  void deactivate() {
    _dragPosition = null;
    _hideTimer?.cancel();
    super.deactivate();
  }

  @override
  void dispose() {
    _disposed = true;
    _dragPosition = null;
    _hideTimer?.cancel();
    _scrollController.removeListener(onChanged);
    _dragGestureRecognizer.dispose();
    super.dispose();
  }

  void _showScrollbar() {
    if (_disposed || !mounted || _position == null) return;
    if (!_isVisible && mounted) {
      setState(() {
        _isVisible = true;
      });
    }
    _hideTimer?.cancel();
  }

  void _scheduleHide() {
    if (_disposed || !mounted) return;
    _hideTimer?.cancel();
    _hideTimer = Timer(_hideDuration, () {
      if (!_disposed && mounted && _isVisible) {
        setState(() {
          _isVisible = false;
        });
      }
    });
  }

  void onUpdate(DragUpdateDetails details) {
    final current = _position;
    final track = viewHeight - _scrollIndicatorSize;
    if (current == null ||
        !identical(current, _dragPosition) ||
        current.maxScrollExtent <= current.minScrollExtent ||
        !track.isFinite ||
        track <= 0 ||
        details.primaryDelta == null) {
      _dragPosition = null;
      return;
    }
    final positionOffset =
        details.primaryDelta! /
        track *
        (current.maxScrollExtent - current.minScrollExtent);
    current.jumpTo(
      (current.pixels + positionOffset).clamp(
        current.minScrollExtent,
        current.maxScrollExtent,
      ),
    );
  }

  ScrollPosition? get _position {
    if (_disposed || !mounted || _scrollController.positions.length != 1) {
      return null;
    }
    final current = _scrollController.position;
    if (!current.hasPixels || !current.hasContentDimensions) return null;
    if (!current.pixels.isFinite ||
        !current.minScrollExtent.isFinite ||
        !current.maxScrollExtent.isFinite) {
      return null;
    }
    return current;
  }

  void _scheduleSync() {
    if (_syncScheduled || _disposed) return;
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (mounted && !_disposed) onChanged();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void onChanged() {
    if (_disposed || !mounted) return;
    final current = _position;
    final min = current?.minScrollExtent ?? 0;
    final max = current?.maxScrollExtent ?? 0;
    final pixels = current?.pixels ?? 0;
    final changed =
        !identical(current, _observedPosition) ||
        min != minExtent ||
        max != maxExtent ||
        pixels != position;
    if (!identical(current, _observedPosition)) _dragPosition = null;
    _observedPosition = current;
    minExtent = min;
    maxExtent = max;
    position = pixels;
    if (current == null) {
      _hideTimer?.cancel();
      _isVisible = false;
    } else if (changed) {
      _showScrollbar();
      _scheduleHide();
    }
    if (changed) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constrains) {
        // Controller listeners do not report attachment or layout-only metric
        // changes. Read the actual current position once this layout finishes.
        _scheduleSync();
        var scrollHeight = (maxExtent - minExtent);
        var height = constrains.maxHeight - widget.topPadding;
        viewHeight = height;
        var top = scrollHeight == 0
            ? 0.0
            : ((position - minExtent) / scrollHeight).clamp(0.0, 1.0) *
                  (height - _scrollIndicatorSize);
        return Stack(
          children: [
            Positioned.fill(
              child: NotificationListener<ScrollMetricsNotification>(
                onNotification: (notification) {
                  if (notification.depth == 0) _scheduleSync();
                  return false;
                },
                child: widget.child,
              ),
            ),
            if (scrollHeight > 0 &&
                height.isFinite &&
                height > _scrollIndicatorSize)
              Positioned(
                top: top + widget.topPadding,
                right: 0,
                child: AnimatedOpacity(
                  opacity: _isVisible ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    onEnter: (_) => _showScrollbar(),
                    onExit: (_) => _scheduleHide(),
                    child: Listener(
                      behavior: HitTestBehavior.translucent,
                      onPointerDown: (event) {
                        _dragGestureRecognizer.addPointer(event);
                      },
                      child: SizedBox(
                        width: _scrollIndicatorSize / 2,
                        height: _scrollIndicatorSize,
                        child: CustomPaint(
                          painter: _ScrollIndicatorPainter(
                            backgroundColor: context.colorScheme.surface,
                            shadowColor: context.colorScheme.shadow,
                          ),
                          child: Column(
                            children: [
                              const Spacer(),
                              Icon(Icons.arrow_drop_up, size: 18),
                              Icon(Icons.arrow_drop_down, size: 18),
                              const Spacer(),
                            ],
                          ).paddingLeft(4),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ScrollIndicatorPainter extends CustomPainter {
  final Color backgroundColor;

  final Color shadowColor;

  const _ScrollIndicatorPainter({
    required this.backgroundColor,
    required this.shadowColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    var path = Path()
      ..moveTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..arcToPoint(Offset(size.width, 0), radius: Radius.circular(size.width));
    canvas.drawShadow(path, shadowColor, 2, true);
    var backgroundPaint = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.fill;
    path = Path()
      ..moveTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..arcToPoint(Offset(size.width, 0), radius: Radius.circular(size.width));
    canvas.drawPath(path, backgroundPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return oldDelegate is! _ScrollIndicatorPainter ||
        oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.shadowColor != shadowColor;
  }
}
