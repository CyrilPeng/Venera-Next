import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/translations.dart';

/// Saves a mounted reader before navigation, retaining its pause until removal.
class ReaderExitGuard extends StatefulWidget {
  const ReaderExitGuard({
    required this.prepare,
    required this.holdForLeave,
    required this.onError,
    required this.child,
    super.key,
  });

  final Future<void Function()> Function() prepare;
  final void Function() Function() holdForLeave;
  final void Function(Object error, StackTrace stackTrace) onError;
  final Widget child;

  @override
  ReaderExitGuardState createState() => ReaderExitGuardState();
}

class ReaderExitGuardState extends State<ReaderExitGuard> {
  final _contentFocus = FocusScopeNode(debugLabel: 'Reader content');
  final _waitingFocus = FocusScopeNode(debugLabel: 'Reader saving');
  final _pointers = <int>{};
  _ExitAttempt? _attempt;
  ModalRoute<dynamic>? _failedRoute;
  FocusNode? _previousFocus;
  bool _closing = false;
  bool _popped = false;

  bool _allowsNavigation() =>
      mounted && !_closing && NavigationAdmission.allows(context);

  Future<void> requestExit() {
    final active = _attempt;
    if (active != null) return active.completion.future;
    if (!mounted || !NavigationAdmission.allows(context)) return Future.value();
    final route = ModalRoute.of(context);
    final navigator = Navigator.of(context);
    if (route == null || !route.isCurrent || !navigator.canPop()) {
      return Future.value();
    }

    final attempt = _ExitAttempt(widget.onError);
    _failedRoute = null;
    _attempt = attempt;
    _freeze();
    unawaited(_prepareExit(attempt, route, navigator, widget.prepare));
    return attempt.completion.future;
  }

  void _freeze() {
    final focus = FocusManager.instance.primaryFocus;
    _previousFocus = focus?.ancestors.contains(_contentFocus) == true
        ? focus
        : null;
    _contentFocus.descendantsAreFocusable = false;
    _waitingFocus.requestFocus();
    setState(() => _closing = true);
    for (final pointer in _pointers.toList()) {
      GestureBinding.instance.cancelPointer(pointer);
    }
  }

  /// An explicit user decision after a failed save. Never bypasses an active
  /// attempt, a covering route, or another owner's navigation restriction.
  void leaveWithoutSaving() {
    if (!mounted || _attempt != null || _closing) return;
    final route = _failedRoute;
    if (route == null ||
        !identical(ModalRoute.of(context), route) ||
        !route.isCurrent ||
        !NavigationAdmission.allows(context)) {
      return;
    }
    final navigator = Navigator.of(context);
    if (!navigator.canPop()) return;
    final attempt = _ExitAttempt(widget.onError);
    _attempt = attempt;
    _freeze();
    try {
      attempt.acceptRelease(widget.holdForLeave());
      if (!mounted || attempt.detached) return;
      if (identical(ModalRoute.of(context), route) &&
          route.isCurrent &&
          navigator.mounted &&
          NavigationAdmission.allows(context)) {
        navigator.pop();
        if (mounted) {
          _popped = !route.isCurrent;
          if (_popped) _failedRoute = null;
        }
      }
    } catch (error, stack) {
      attempt.report(error, stack);
    } finally {
      _finishAttempt(attempt, route);
    }
  }

  Future<void> _prepareExit(
    _ExitAttempt attempt,
    ModalRoute<dynamic> route,
    NavigatorState navigator,
    Future<void Function()> Function() prepare,
  ) async {
    var prepared = false;
    try {
      final release = await prepare();
      prepared = true;
      attempt.acceptRelease(release);
      if (!mounted || attempt.detached) return;
      // Another route or the desktop shutdown guard may have taken ownership
      // while storage was pending. Never pop or focus that replacement owner.
      if (identical(ModalRoute.of(context), route) &&
          route.isCurrent &&
          navigator.mounted &&
          NavigationAdmission.allows(context)) {
        navigator.pop();
        if (mounted) _popped = !route.isCurrent;
      }
    } catch (error, stack) {
      if (!prepared && mounted && identical(_attempt, attempt)) {
        _failedRoute = route;
      }
      attempt.report(error, stack);
    } finally {
      _finishAttempt(attempt, route);
    }
  }

  void _finishAttempt(_ExitAttempt attempt, ModalRoute<dynamic> route) {
    if (!mounted || !_popped) {
      try {
        attempt.release();
      } finally {
        if (mounted && identical(_attempt, attempt)) {
          _attempt = null;
          _contentFocus.descendantsAreFocusable = true;
          setState(() => _closing = false);
          final previous = _previousFocus;
          _previousFocus = null;
          if (route.isCurrent &&
              NavigationAdmission.allows(context) &&
              previous?.context != null &&
              previous!.canRequestFocus) {
            previous.requestFocus();
          }
        }
      }
    }
    attempt.completion.complete();
  }

  @override
  void dispose() {
    final attempt = _attempt;
    if (attempt != null) {
      attempt.detached = true;
      attempt.release();
    }
    _contentFocus.dispose();
    _waitingFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(requestExit());
    },
    child: CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            unawaited(requestExit()),
      },
      child: Listener(
        onPointerDown: (event) => _pointers.add(event.pointer),
        onPointerUp: (event) => _pointers.remove(event.pointer),
        onPointerCancel: (event) => _pointers.remove(event.pointer),
        child: NavigationAdmission(
          allowsNavigation: _allowsNavigation,
          child: Stack(
            fit: StackFit.expand,
            children: [
              FocusScope(
                node: _contentFocus,
                onKeyEvent: (_, _) =>
                    _closing ? KeyEventResult.handled : KeyEventResult.ignored,
                child: ExcludeSemantics(
                  excluding: _closing,
                  child: AbsorbPointer(
                    absorbing: _closing,
                    child: widget.child,
                  ),
                ),
              ),
              if (_closing && !_popped)
                Positioned.fill(
                  child: BlockSemantics(
                    child: FocusScope(
                      node: _waitingFocus,
                      autofocus: true,
                      onKeyEvent: (_, _) => KeyEventResult.handled,
                      child: ColoredBox(
                        color: Theme.of(
                          context,
                        ).colorScheme.scrim.withValues(alpha: 0.45),
                        child: Center(
                          child: AlertDialog(
                            scrollable: true,
                            title: Semantics(
                              liveRegion: true,
                              child: Text('Saving...'.tl),
                            ),
                            content: TickerMode(
                              enabled: !MediaQuery.disableAnimationsOf(context),
                              child: const LinearProgressIndicator(),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Owns a returned hold independently of the widget's mount lifetime.
class _ExitAttempt {
  _ExitAttempt(this.onError);

  final void Function(Object error, StackTrace stackTrace) onError;
  final completion = Completer<void>();
  VoidCallback? _release;
  bool _released = false;
  bool detached = false;

  void acceptRelease(VoidCallback release) {
    if (_released) {
      _invokeRelease(release);
    } else {
      _release = release;
    }
  }

  void release() {
    if (_released) return;
    _released = true;
    final release = _release;
    _release = null;
    if (release != null) _invokeRelease(release);
  }

  void _invokeRelease(VoidCallback release) {
    try {
      release();
    } catch (error, stack) {
      report(error, stack);
    }
  }

  void report(Object error, StackTrace stack) {
    if (!detached) {
      try {
        onError(error, stack);
        return;
      } catch (reportingError, reportingStack) {
        _reportFlutterError(
          FlutterErrorDetails(
            exception: reportingError,
            stack: reportingStack,
            library: 'reader exit error reporting',
          ),
        );
      }
    }
    _reportFlutterError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'reader exit',
      ),
    );
  }

  void _reportFlutterError(FlutterErrorDetails details) {
    try {
      FlutterError.reportError(details);
    } catch (_) {
      // A diagnostic handler must not interrupt hold release or UI recovery.
    }
  }
}
