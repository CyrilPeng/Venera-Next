import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_page_route.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/selection_operation.dart';

class SideBarRoute<T> extends PopupRoute<T> {
  SideBarRoute(
    this.widget, {
    this.showBarrier = true,
    this.useSurfaceTintColor = false,
    this.dismissible = true,
    required this.width,
    this.addBottomPadding = true,
    this.addTopPadding = true,
    this.transitionDuration = const Duration(milliseconds: 300),
    this.onDispose,
    this.isOwnerActive,
  });

  final Widget widget;

  final bool showBarrier;

  final bool useSurfaceTintColor;

  final bool dismissible;

  final double width;

  final bool addTopPadding;

  final bool addBottomPadding;

  final VoidCallback? onDispose;

  final bool Function()? isOwnerActive;

  bool _barrierSawPointerDown = false;

  bool get _canInteract =>
      navigator?.mounted == true &&
      isActive &&
      isCurrent &&
      (isOwnerActive?.call() ?? true);

  @override
  Color? get barrierColor => showBarrier ? Colors.black54 : Colors.transparent;

  @override
  bool get barrierDismissible => dismissible;

  @override
  String? get barrierLabel => "exit";

  @override
  TickerFuture didPush() {
    _barrierSawPointerDown = false;
    return super.didPush();
  }

  @override
  void dispose() {
    try {
      onDispose?.call();
    } finally {
      super.dispose();
    }
  }

  @override
  Widget buildModalBarrier() {
    if (!showBarrier) {
      return const SizedBox.shrink();
    }
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        if (!_canInteract || event.position == Offset.zero) {
          return;
        }
        _barrierSawPointerDown = true;
      },
      child: ModalBarrier(
        dismissible: dismissible,
        onDismiss: dismissible
            ? () {
                if (!_canInteract || !_barrierSawPointerDown) {
                  return;
                }
                navigator?.maybePop();
              }
            : null,
        color: barrierColor,
        semanticsLabel: barrierLabel,
      ),
    );
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    bool showSideBar = MediaQuery.of(context).size.width > width;

    Widget body = widget;

    if (addTopPadding) {
      body = Padding(
        padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
        child: MediaQuery.removePadding(
          context: context,
          removeTop: true,
          child: body,
        ),
      );
    }

    final sideBarWidth = math.min(width, MediaQuery.of(context).size.width);

    body = Container(
      decoration: BoxDecoration(
        borderRadius: showSideBar
            ? const BorderRadius.horizontal(left: Radius.circular(16))
            : null,
        color: Theme.of(context).colorScheme.surfaceTint,
        boxShadow: context.brightness == ui.Brightness.dark
            ? [
                BoxShadow(
                  color: Colors.white.withAlpha(50),
                  blurRadius: 10,
                  offset: Offset(0, 2),
                ),
              ]
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      constraints: BoxConstraints(maxWidth: sideBarWidth),
      height: MediaQuery.of(context).size.height,
      child: GestureDetector(
        child: Material(
          child: ClipRect(
            clipBehavior: Clip.antiAlias,
            child: Container(
              padding: EdgeInsets.fromLTRB(
                0,
                0,
                MediaQuery.of(context).padding.right,
                addBottomPadding
                    ? MediaQuery.of(context).padding.bottom +
                          MediaQuery.of(context).viewInsets.bottom
                    : 0,
              ),
              color: useSurfaceTintColor
                  ? Theme.of(context).colorScheme.surfaceTint.withAlpha(20)
                  : null,
              child: body,
            ),
          ),
        ),
      ),
    );

    if (App.isIOS) {
      body = IOSBackGestureDetector(
        enabledCallback: () => _canInteract,
        gestureWidth: 20.0,
        onStartPopGesture: () =>
            IOSBackGestureController(controller!, navigator!, route: this),
        child: body,
      );
    }

    return Align(alignment: Alignment.centerRight, child: body);
  }

  @override
  final Duration transitionDuration;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    var offset = Tween<Offset>(
      begin: const Offset(1, 0),
      end: const Offset(0, 0),
    );
    return SlideTransition(
      position: offset.animate(
        CurvedAnimation(parent: animation, curve: Curves.fastOutSlowIn),
      ),
      child: child,
    );
  }
}

Future<T?> showSideBar<T>(
  BuildContext context,
  Widget widget, {
  bool showBarrier = true,
  bool useSurfaceTintColor = false,
  bool dismissible = true,
  double width = 500,
  bool addTopPadding = false,
}) {
  if (!context.mounted) return Future<T?>.value(null);
  final task = WindowSelectionTask(context);
  final navigator = Navigator.of(context);
  final disposed = Completer<T?>();
  final removalFailed = Completer<T?>();
  removalFailed.future.ignore();
  SideBarRoute<T>? route;

  void finish() {
    if (!disposed.isCompleted) disposed.complete(null);
  }

  bool isOwnerActive() =>
      task.active && Navigator.maybeOf(context) == navigator;

  Future<T?> present() async {
    try {
      return await task.run((operation) async {
        operation.checkActive();
        if (!isOwnerActive()) throw const SelectionCancelled();
        final sidebar = route = SideBarRoute<T>(
          widget,
          showBarrier: showBarrier,
          useSurfaceTintColor: useSurfaceTintColor,
          dismissible: dismissible,
          width: width,
          addTopPadding: addTopPadding,
          addBottomPadding: true,
          onDispose: finish,
          isOwnerActive: isOwnerActive,
        );
        final release = task.retainPresentation(() {
          try {
            if (navigator.mounted && sidebar.isActive) {
              navigator.removeRoute(sidebar);
            } else {
              finish();
            }
          } catch (error, stack) {
            if (!removalFailed.isCompleted) {
              removalFailed.completeError(error, stack);
            }
            rethrow;
          }
        }, isCurrent: () => sidebar.isCurrent);
        final selected = await Future.any<T?>([
          navigator.push(sidebar),
          disposed.future,
          removalFailed.future,
        ]);
        release();
        return selected;
      });
    } on SelectionCancelled {
      return null;
    } finally {
      if (route?.navigator == null) finish();
    }
  }

  final result = present();
  // Some presentation-only callers deliberately do not await a result. Keep
  // their error observed while returning the original failed future to callers
  // that do await it; the original host still owns any failed route cleanup.
  unawaited(
    result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        Log.error('Sidebar presentation', error, stack);
      },
    ),
  );
  return result;
}
