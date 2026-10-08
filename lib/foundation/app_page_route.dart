import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:venera_next/foundation/edge_back_gesture.dart';
import 'package:venera_next/foundation/app.dart';

const double _kBackGestureWidth = 24.0;
const int _kMaxDroppedSwipePageForwardAnimationTime = 800;
const int _kMaxPageBackAnimationTime = 300;
const double _kMinFlingVelocity = 1.0;

class AppPageRoute<T> extends PageRoute<T> with _AppRouteTransitionMixin {
  /// Construct a MaterialPageRoute whose contents are defined by [builder].
  AppPageRoute({
    required this.builder,
    super.settings,
    this.maintainState = true,
    super.fullscreenDialog,
    super.allowSnapshotting = true,
    super.barrierDismissible = false,
    this.enableIOSGesture = true,
    this.preventRebuild = true,
  }) {
    assert(opaque);
  }

  /// Builds the primary contents of the route.
  final WidgetBuilder builder;

  String? label;

  @override
  toString() => "/$label";

  @override
  Widget buildContent(BuildContext context) {
    var widget = builder(context);
    label = widget.runtimeType.toString();
    return widget;
  }

  @override
  final bool maintainState;

  @override
  String get debugLabel => '${super.debugLabel}(${settings.name})';

  @override
  final bool enableIOSGesture;

  @override
  final bool preventRebuild;
}

mixin _AppRouteTransitionMixin<T> on PageRoute<T> {
  /// Builds the primary contents of the route.
  @protected
  Widget buildContent(BuildContext context);

  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool canTransitionTo(TransitionRoute<dynamic> nextRoute) {
    // Don't perform outgoing animation if the next route is a fullscreen dialog.
    return nextRoute is PageRoute && !nextRoute.fullscreenDialog;
  }

  bool get enableIOSGesture;

  bool get preventRebuild;

  Widget? _child;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    Widget result;

    if (preventRebuild) {
      result = _child ?? (_child = buildContent(context));
    } else {
      result = buildContent(context);
    }

    return Semantics(
      scopesRoute: true,
      explicitChildNodes: true,
      child: result,
    );
  }

  static bool _isPopGestureEnabled<T>(PageRoute<T> route) {
    if (route.isFirst ||
        route.willHandlePopInternally ||
        route.popDisposition == RoutePopDisposition.doNotPop ||
        route.fullscreenDialog ||
        route.animation!.status != AnimationStatus.completed ||
        route.secondaryAnimation!.status != AnimationStatus.dismissed ||
        !route.popGestureEnabled ||
        route.navigator!.userGestureInProgress) {
      return false;
    }

    return true;
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    PageTransitionsBuilder builder;
    if (App.isAndroid) {
      builder = PredictiveBackPageTransitionsBuilder();
    } else {
      builder = SlidePageTransitionBuilder();
    }

    return builder.buildTransitions(
      this,
      context,
      animation,
      secondaryAnimation,
      enableIOSGesture && App.isIOS
          ? IOSBackGestureDetector(
              gestureWidth: _kBackGestureWidth,
              enabledCallback: () => _isPopGestureEnabled<T>(this),
              onStartPopGesture: () => _startPopGesture(this),
              child: child,
            )
          : child,
    );
  }

  IOSBackGestureController _startPopGesture(PageRoute<T> route) {
    return IOSBackGestureController(
      route.controller!,
      route.navigator!,
      route: route,
    );
  }
}

class IOSBackGestureController {
  final AnimationController controller;

  final NavigatorState navigator;
  final Route<dynamic> route;
  AnimationStatusListener? _statusListener;
  bool _ended = false;
  bool _finished = false;
  bool _disposing = false;

  IOSBackGestureController(
    this.controller,
    this.navigator, {
    required this.route,
  }) {
    navigator.didStartUserGesture();
  }

  void dragEnd(double velocity, {bool cancelled = false}) {
    if (_ended || _finished) return;
    _ended = true;
    const Curve animationCurve = Curves.fastLinearToSlowEaseIn;
    final bool animateForward;

    if (!route.isCurrent) {
      // A late pointer must not pop a route pushed after this gesture started.
      animateForward = route.isActive;
    } else if (cancelled) {
      animateForward = true;
    } else if (velocity.abs() >= _kMinFlingVelocity && controller.value < 0.9) {
      animateForward = velocity <= 0;
    } else {
      animateForward = controller.value > 0.5;
    }

    if (animateForward) {
      final droppedPageForwardAnimationTime = min(
        lerpDouble(
          _kMaxDroppedSwipePageForwardAnimationTime,
          0,
          controller.value,
        )!.floor(),
        _kMaxPageBackAnimationTime,
      );
      controller.animateTo(
        1.0,
        duration: Duration(milliseconds: droppedPageForwardAnimationTime),
        curve: animationCurve,
      );
    } else {
      if (route.isCurrent) navigator.pop();
      if (controller.isAnimating) {
        final droppedPageBackAnimationTime = lerpDouble(
          0,
          _kMaxDroppedSwipePageForwardAnimationTime,
          controller.value,
        )!.floor();
        controller.animateBack(
          0.0,
          duration: Duration(milliseconds: droppedPageBackAnimationTime),
          curve: animationCurve,
        );
      }
    }

    if (controller.isAnimating) {
      _statusListener = (_) => _finish();
      controller.addStatusListener(_statusListener!);
    } else {
      _finish();
    }
  }

  void dragUpdate(double delta) {
    if (_ended || _finished) return;
    controller.value -= delta;
  }

  void _finish() {
    if (_finished) return;
    _finished = true;
    final listener = _statusListener;
    _statusListener = null;
    if (listener != null) controller.removeStatusListener(listener);
    void stop() {
      if (navigator.mounted) navigator.didStopUserGesture();
    }

    if (_disposing) {
      // Navigator listeners can rebuild; owner disposal may run during build.
      WidgetsBinding.instance.addPostFrameCallback((_) => stop());
      WidgetsBinding.instance.ensureVisualUpdate();
    } else {
      stop();
    }
  }

  /// Releases this gesture and its listener, never the route-owned controller.
  void dispose() {
    if (_finished) return;
    _disposing = true;
    if (!_ended && navigator.mounted && route.isActive) {
      dragEnd(0, cancelled: true);
    }
    _ended = true;
    _finish();
  }
}

class IOSBackGestureDetector extends StatefulWidget {
  const IOSBackGestureDetector({
    required this.enabledCallback,
    required this.child,
    required this.gestureWidth,
    required this.onStartPopGesture,
    super.key,
  });

  final double gestureWidth;
  final bool Function() enabledCallback;
  final IOSBackGestureController Function() onStartPopGesture;
  final Widget child;

  @override
  State<IOSBackGestureDetector> createState() => _IOSBackGestureDetectorState();
}

class _IOSBackGestureDetectorState extends State<IOSBackGestureDetector> {
  IOSBackGestureController? _backGestureController;

  void _releaseGesture() {
    final previous = _backGestureController;
    _backGestureController = null;
    previous?.dispose();
  }

  @override
  void deactivate() {
    _releaseGesture();
    super.deactivate();
  }

  @override
  void dispose() {
    _releaseGesture();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return EdgeBackGestureDetector(
      enabled: widget.enabledCallback,
      edgeWidth: widget.gestureWidth,
      onStart: () {
        _releaseGesture();
        _backGestureController = widget.onStartPopGesture();
      },
      onUpdate: (delta) => _backGestureController?.dragUpdate(delta),
      onEnd: (velocity) {
        _backGestureController?.dragEnd(velocity);
      },
      onCancel: () {
        _backGestureController?.dragEnd(0, cancelled: true);
      },
      child: widget.child,
    );
  }
}

class SlidePageTransitionBuilder extends PageTransitionsBuilder {
  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final Animation<double> primaryAnimation = App.isIOS
        ? animation
        : animation.drive(CurveTween(curve: Curves.ease));
    final Animation<double> secondaryCurve = App.isIOS
        ? secondaryAnimation
        : secondaryAnimation.drive(CurveTween(curve: Curves.ease));

    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(primaryAnimation),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: Offset.zero,
          end: const Offset(-0.4, 0),
        ).animate(secondaryCurve),
        child: PhysicalModel(
          color: Colors.transparent,
          borderRadius: BorderRadius.zero,
          clipBehavior: Clip.hardEdge,
          elevation: 6,
          child: Material(child: child),
        ),
      ),
    );
  }
}
