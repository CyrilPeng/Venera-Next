import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/consts.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';
import 'package:window_manager/window_manager.dart';

const _kTitleBarHeight = 36.0;

class WindowFrameController extends InheritedWidget {
  /// Reads the live host state, including when this controller was retained
  /// before close started. New owners must join an in-progress close.
  bool get isClosing => _isClosing();
  final bool Function() _isClosing;

  /// Whether the window frame is hidden.
  final bool isWindowFrameHidden;

  /// Sets the visibility of the window frame.
  final void Function(bool) setWindowFrame;

  /// Adds a listener that will be called when close button is clicked.
  /// The listener should return `true` to allow the window to be closed.
  final void Function(WindowCloseListener listener) addCloseListener;

  /// Removes a close listener.
  final void Function(WindowCloseListener listener) removeCloseListener;

  /// Synchronously freezes owners after guards accept close, before any waits.
  final void Function(VoidCallback listener) addCloseStartListener,
      removeCloseStartListener;

  /// Final shutdown tasks run in reverse registration order after close guards.
  final void Function(Future<void> Function() task) addExitTask, removeExitTask;
  final void Function(Future<void> task) trackExitTask;
  final void Function(VoidCallback listener) addCloseFailureListener,
      removeCloseFailureListener;
  final VoidCallback forceExit;

  const WindowFrameController._create({
    required bool Function() isClosing,
    required this.isWindowFrameHidden,
    required this.setWindowFrame,
    required this.addCloseListener,
    required this.removeCloseListener,
    required this.addCloseStartListener,
    required this.removeCloseStartListener,
    required this.addExitTask,
    required this.removeExitTask,
    required this.trackExitTask,
    required this.addCloseFailureListener,
    required this.removeCloseFailureListener,
    required this.forceExit,
    required super.child,
  }) : _isClosing = isClosing;

  @override
  bool updateShouldNotify(covariant InheritedWidget oldWidget) {
    return false;
  }
}

class WindowFrame extends StatefulWidget {
  const WindowFrame(this.child, {this.debugAction, this.onExit, super.key});

  final Widget child;

  final VoidCallback? debugAction;
  final VoidCallback? onExit;

  @override
  State<WindowFrame> createState() => _WindowFrameState();

  static WindowFrameController of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<WindowFrameController>()!;
  }
}

typedef WindowCloseListener = bool Function();

class _WindowFrameState extends State<WindowFrame> with WindowListener {
  bool isWindowFrameHidden = false;
  bool useDarkTheme = false;
  var closeListeners = <WindowCloseListener>[];
  final _exitTasks = <Future<void> Function()>[];
  final _pendingExitTasks = <Future<void>>{};
  final _closeStartListeners = <VoidCallback>[];
  final _closeFailureListeners = <VoidCallback>[];
  final _activePointers = <int>{};
  final _contentFocus = FocusScopeNode(debugLabel: 'window content');
  final _shutdownFocus = FocusScopeNode(
    debugLabel: 'window shutdown',
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
  );
  FocusNode? _previousFocus;
  bool _closing = false;
  bool _exited = false;

  @override
  void initState() {
    super.initState();
    if (App.isDesktop) windowManager.addListener(this);
  }

  @override
  void onWindowClose() => _onClose();

  @override
  void dispose() {
    if (App.isDesktop) windowManager.removeListener(this);
    _contentFocus.dispose();
    _shutdownFocus.dispose();
    super.dispose();
  }

  /// Sets the visibility of the window frame.
  void setWindowFrame(bool show) {
    setState(() {
      isWindowFrameHidden = !show;
    });
  }

  /// Adds a listener that will be called when close button is clicked.
  /// The listener should return `true` to allow the window to be closed.
  void addCloseListener(WindowCloseListener listener) {
    closeListeners.add(listener);
  }

  /// Removes a close listener.
  void removeCloseListener(WindowCloseListener listener) {
    closeListeners.remove(listener);
  }

  void _forceExit() {
    if (!mounted || _exited) return;
    setState(() => _exited = true);
    (widget.onExit ?? () => exit(0))();
  }

  void _trackExitTask(Future<void> task) {
    late final Future<void> pending;
    pending = task.then<void>(
      (_) {
        _pendingExitTasks.remove(pending);
      },
      onError: (Object error, StackTrace stack) {
        // Keep a failed write visible to the next drain during shutdown. It
        // may fail while another owner's callback is still being awaited.
        if (!_closing || !mounted) _pendingExitTasks.remove(pending);
        Error.throwWithStackTrace(error, stack);
      },
    );
    _pendingExitTasks.add(pending);
    // Report failures even if no close attempt is currently waiting.
    unawaited(
      pending.catchError((Object error, StackTrace stack) {
        if (!_closing || !mounted) _reportExitError(error, stack);
      }),
    );
  }

  void _reportExitError(Object error, StackTrace stack) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'window shutdown',
      ),
    );
  }

  void _onClose() async {
    if (_closing || _exited) return;
    for (var listener in List.of(closeListeners)) {
      if (!closeListeners.contains(listener)) continue;
      if (!listener()) {
        return;
      }
    }
    _previousFocus = FocusManager.instance.primaryFocus;
    _contentFocus.descendantsAreFocusable = false;
    setState(() => _closing = true);
    for (final pointer in _activePointers.toList()) {
      GestureBinding.instance.cancelPointer(pointer);
    }
    try {
      final startFailures = <({Object error, StackTrace stack})>[];
      for (final listener in _closeStartListeners.toList()) {
        if (!_closeStartListeners.contains(listener)) continue;
        try {
          listener();
        } catch (error, stack) {
          // Keep freezing the remaining owners even if one cannot prepare.
          // Recovery waits until all accepted work is drained below.
          startFailures.add((error: error, stack: stack));
        }
      }
      if (startFailures.isNotEmpty) {
        for (final failure in startFailures.skip(1)) {
          _reportExitError(failure.error, failure.stack);
        }
        final failure = startFailures.first;
        Error.throwWithStackTrace(failure.error, failure.stack);
      }
      // A disposed reader may already have detached its callback but still be
      // saving. Drain it before application-level sync inspects pending uploads.
      await _drainPendingExitTasks();
      for (final task in _exitTasks.reversed.toList()) {
        if (!mounted || _exited) return;
        if (_exitTasks.contains(task)) await task();
        // A callback may dispose an owner and register its final writes.
        // Join those writes before the next owner prepares or the host exits.
        await _drainPendingExitTasks();
      }
      _forceExit();
    } catch (error, stack) {
      // A callback can fail after registering writes. Keep admission closed
      // until those writes have settled before releasing other services.
      try {
        await _drainPendingExitTasks();
      } catch (drainError, drainStack) {
        if (!identical(drainError, error)) {
          _reportExitError(drainError, drainStack);
        }
      }
      for (final listener in _closeFailureListeners.reversed.toList()) {
        if (!_closeFailureListeners.contains(listener)) continue;
        try {
          listener();
        } catch (releaseError, releaseStack) {
          _reportExitError(releaseError, releaseStack);
        }
      }
      _reportExitError(error, stack);
      if (mounted && !_exited) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text('Unable to close. Please try again.'.tl),
            action: SnackBarAction(label: 'Retry'.tl, onPressed: _onClose),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _closing = false);
        if (!_exited) {
          _contentFocus.descendantsAreFocusable = true;
          final previous = _previousFocus;
          if (previous?.context != null && previous!.canRequestFocus) {
            previous.requestFocus();
          }
        }
      }
      _closing = false;
      _previousFocus = null;
    }
  }

  Future<void> _drainPendingExitTasks() async {
    final failures = <({Object error, StackTrace stack})>[];
    while (_pendingExitTasks.isNotEmpty) {
      final batch = _pendingExitTasks.toList();
      await Future.wait(
        batch.map((task) async {
          try {
            await task;
          } catch (error, stack) {
            failures.add((error: error, stack: stack));
          }
        }),
      );
      _pendingExitTasks.removeAll(batch);
    }
    if (failures.isNotEmpty) {
      for (final failure in failures.skip(1)) {
        _reportExitError(failure.error, failure.stack);
      }
      Error.throwWithStackTrace(failures.first.error, failures.first.stack);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (App.isMobile) return widget.child;

    Widget body = Stack(
      children: [
        Positioned.fill(
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: isWindowFrameHidden
                  ? null
                  : const EdgeInsets.only(top: _kTitleBarHeight),
            ),
            child: widget.child,
          ),
        ),
        if (!isWindowFrameHidden)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Material(
              color: Colors.transparent,
              child: Theme(
                data: Theme.of(
                  context,
                ).copyWith(brightness: useDarkTheme ? Brightness.dark : null),
                child: Builder(
                  builder: (context) {
                    return SizedBox(
                      height: _kTitleBarHeight,
                      child: Row(
                        children: [
                          if (App.isMacOS)
                            const DragToMoveArea(
                              child: SizedBox(
                                height: double.infinity,
                                width: 16,
                              ),
                            ).paddingRight(52)
                          else
                            const SizedBox(width: 12),
                          const SizedBox(width: 12),
                          Expanded(
                            child: DragToMoveArea(
                              child: _WindowBrand(
                                showTitle: context.width >= changePoint2,
                                dark:
                                    useDarkTheme ||
                                    context.brightness == Brightness.dark,
                              ),
                            ),
                          ),
                          if (kDebugMode && widget.debugAction != null)
                            TextButton(
                              onPressed: widget.debugAction,
                              child: Text('Debug'),
                            ),
                          if (!App.isMacOS) _WindowButtons(onClose: _onClose),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
      ],
    );

    if (App.isLinux) {
      body = VirtualWindowFrame(child: body);
    }

    return WindowFrameController._create(
      isClosing: () => _closing || _exited,
      isWindowFrameHidden: isWindowFrameHidden,
      setWindowFrame: setWindowFrame,
      addCloseListener: addCloseListener,
      removeCloseListener: removeCloseListener,
      addCloseStartListener: _closeStartListeners.add,
      removeCloseStartListener: _closeStartListeners.remove,
      addExitTask: _exitTasks.add,
      removeExitTask: _exitTasks.remove,
      trackExitTask: _trackExitTask,
      addCloseFailureListener: _closeFailureListeners.add,
      removeCloseFailureListener: _closeFailureListeners.remove,
      forceExit: _forceExit,
      child: Listener(
        onPointerDown: (event) => _activePointers.add(event.pointer),
        onPointerUp: (event) => _activePointers.remove(event.pointer),
        onPointerCancel: (event) => _activePointers.remove(event.pointer),
        child: NavigationAdmission(
          allowsNavigation: () => mounted && !_closing && !_exited,
          child: Stack(
            children: [
              FocusScope(
                node: _contentFocus,
                child: ExcludeSemantics(
                  excluding: _closing || _exited,
                  child: AbsorbPointer(
                    absorbing: _closing || _exited,
                    child: body,
                  ),
                ),
              ),
              if (_closing && !_exited)
                Positioned.fill(
                  child: BlockSemantics(
                    child: FocusScope(
                      node: _shutdownFocus,
                      autofocus: true,
                      child: Shortcuts(
                        shortcuts: const {
                          SingleActivator(LogicalKeyboardKey.escape):
                              DoNothingAndStopPropagationIntent(),
                        },
                        child: ColoredBox(
                          color: Theme.of(
                            context,
                          ).colorScheme.scrim.withValues(alpha: 0.45),
                          child: Center(
                            child: AlertDialog(
                              title: Semantics(
                                liveRegion: true,
                                child: Text('Closing...'.tl),
                              ),
                              content: TickerMode(
                                enabled: !MediaQuery.disableAnimationsOf(
                                  context,
                                ),
                                child: const LinearProgressIndicator(),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: _forceExit,
                                  child: Text('Force Quit'.tl),
                                ),
                              ],
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
    );
  }
}

class _WindowBrand extends StatelessWidget {
  const _WindowBrand({required this.showTitle, required this.dark});

  final bool showTitle;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final foreground = dark ? Colors.white : Colors.black;
    final title = Text(
      'VeneraNext',
      style: TextStyle(fontSize: 13, color: foreground),
      overflow: TextOverflow.ellipsis,
      maxLines: 1,
    );
    final logo = Image.asset(
      'assets/app_icon.png',
      width: 24,
      height: 24,
      filterQuality: FilterQuality.medium,
    );

    return Align(
      alignment: Alignment.centerLeft,
      child: Semantics(
        label: 'VeneraNext',
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 32),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              logo,
              if (showTitle) ...[
                const SizedBox(width: 8),
                Flexible(child: title),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _WindowButtons extends StatefulWidget {
  const _WindowButtons({required this.onClose});

  final void Function() onClose;

  @override
  State<_WindowButtons> createState() => _WindowButtonsState();
}

class _WindowButtonsState extends State<_WindowButtons> with WindowListener {
  bool isMaximized = false;

  @override
  void initState() {
    windowManager.addListener(this);
    windowManager.isMaximized().then((value) {
      if (value) {
        setState(() {
          isMaximized = true;
        });
      }
    });
    super.initState();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() {
    setState(() {
      isMaximized = true;
    });
    super.onWindowMaximize();
  }

  @override
  void onWindowUnmaximize() {
    setState(() {
      isMaximized = false;
    });
    super.onWindowUnmaximize();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = dark ? Colors.white : Colors.black;
    final hoverColor = dark ? Colors.white30 : Colors.black12;

    return SizedBox(
      width: 138,
      height: _kTitleBarHeight,
      child: Row(
        children: [
          WindowButton(
            icon: MinimizeIcon(color: color),
            hoverColor: hoverColor,
            onPressed: () async {
              bool isMinimized = await windowManager.isMinimized();
              if (isMinimized) {
                windowManager.restore();
              } else {
                windowManager.minimize();
              }
            },
          ),
          if (isMaximized)
            WindowButton(
              icon: RestoreIcon(color: color),
              hoverColor: hoverColor,
              onPressed: () {
                windowManager.unmaximize();
              },
            )
          else
            WindowButton(
              icon: MaximizeIcon(color: color),
              hoverColor: hoverColor,
              onPressed: () {
                windowManager.maximize();
              },
            ),
          WindowButton(
            icon: CloseIcon(color: color),
            hoverIcon: CloseIcon(color: !dark ? Colors.white : Colors.black),
            hoverColor: Colors.red,
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }
}

class WindowButton extends StatefulWidget {
  const WindowButton({
    required this.icon,
    required this.onPressed,
    required this.hoverColor,
    this.hoverIcon,
    super.key,
  });

  final Widget icon;

  final void Function() onPressed;

  final Color hoverColor;

  final Widget? hoverIcon;

  @override
  State<WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<WindowButton> {
  bool isHovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (event) => setState(() {
        isHovering = true;
      }),
      onExit: (event) => setState(() {
        isHovering = false;
      }),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: Container(
          width: 46,
          height: double.infinity,
          decoration: BoxDecoration(
            color: isHovering ? widget.hoverColor : null,
          ),
          child: isHovering ? widget.hoverIcon ?? widget.icon : widget.icon,
        ),
      ),
    );
  }
}

/// Close
class CloseIcon extends StatelessWidget {
  final Color color;

  const CloseIcon({super.key, required this.color});

  @override
  Widget build(BuildContext context) => _AlignedPaint(_ClosePainter(color));
}

class _ClosePainter extends _IconPainter {
  _ClosePainter(super.color);

  @override
  void paint(Canvas canvas, Size size) {
    Paint p = getPaint(color, true);
    canvas.drawLine(const Offset(0, 0), Offset(size.width, size.height), p);
    canvas.drawLine(Offset(0, size.height), Offset(size.width, 0), p);
  }
}

/// Maximize
class MaximizeIcon extends StatelessWidget {
  final Color color;

  const MaximizeIcon({super.key, required this.color});

  @override
  Widget build(BuildContext context) => _AlignedPaint(_MaximizePainter(color));
}

class _MaximizePainter extends _IconPainter {
  _MaximizePainter(super.color);

  @override
  void paint(Canvas canvas, Size size) {
    Paint p = getPaint(color);
    canvas.drawRect(Rect.fromLTRB(0, 0, size.width - 1, size.height - 1), p);
  }
}

/// Restore
class RestoreIcon extends StatelessWidget {
  final Color color;

  const RestoreIcon({super.key, required this.color});

  @override
  Widget build(BuildContext context) => _AlignedPaint(_RestorePainter(color));
}

class _RestorePainter extends _IconPainter {
  _RestorePainter(super.color);

  @override
  void paint(Canvas canvas, Size size) {
    Paint p = getPaint(color);
    canvas.drawRect(Rect.fromLTRB(0, 2, size.width - 2, size.height), p);
    canvas.drawLine(const Offset(2, 2), const Offset(2, 0), p);
    canvas.drawLine(const Offset(2, 0), Offset(size.width, 0), p);
    canvas.drawLine(
      Offset(size.width, 0),
      Offset(size.width, size.height - 2),
      p,
    );
    canvas.drawLine(
      Offset(size.width, size.height - 2),
      Offset(size.width - 2, size.height - 2),
      p,
    );
  }
}

/// Minimize
class MinimizeIcon extends StatelessWidget {
  final Color color;

  const MinimizeIcon({super.key, required this.color});

  @override
  Widget build(BuildContext context) => _AlignedPaint(_MinimizePainter(color));
}

class _MinimizePainter extends _IconPainter {
  _MinimizePainter(super.color);

  @override
  void paint(Canvas canvas, Size size) {
    Paint p = getPaint(color);
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      p,
    );
  }
}

/// Helpers
abstract class _IconPainter extends CustomPainter {
  _IconPainter(this.color);

  final Color color;

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _AlignedPaint extends StatelessWidget {
  const _AlignedPaint(this.painter);

  final CustomPainter painter;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.center,
      child: CustomPaint(size: const Size(10, 10), painter: painter),
    );
  }
}

Paint getPaint(Color color, [bool isAntiAlias = false]) => Paint()
  ..color = color
  ..style = PaintingStyle.stroke
  ..isAntiAlias = isAntiAlias
  ..strokeWidth = 1;

class VirtualWindowFrame extends StatefulWidget {
  const VirtualWindowFrame({super.key, required this.child});

  /// The [child] contained by the VirtualWindowFrame.
  final Widget child;

  @override
  State<StatefulWidget> createState() => _VirtualWindowFrameState();
}

class _VirtualWindowFrameState extends State<VirtualWindowFrame>
    with WindowListener {
  bool _isFocused = true;
  bool _isMaximized = false;
  bool _isFullScreen = false;

  @override
  void initState() {
    windowManager.addListener(this);
    super.initState();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Widget _buildVirtualWindowFrame(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_isMaximized ? 0 : 8),
        color: Colors.transparent,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.toOpacity(_isFocused ? 0.4 : 0.2),
            blurRadius: 4,
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: widget.child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return DragToResizeArea(
      enableResizeEdges: (_isMaximized || _isFullScreen) ? [] : null,
      child: Padding(
        padding: EdgeInsets.all(_isMaximized ? 0 : 4),
        child: _buildVirtualWindowFrame(context),
      ),
    );
  }

  @override
  void onWindowFocus() {
    setState(() {
      _isFocused = true;
    });
  }

  @override
  void onWindowBlur() {
    setState(() {
      _isFocused = false;
    });
  }

  @override
  void onWindowMaximize() {
    setState(() {
      _isMaximized = true;
    });
  }

  @override
  void onWindowUnmaximize() {
    setState(() {
      _isMaximized = false;
    });
  }

  @override
  void onWindowEnterFullScreen() {
    setState(() {
      _isFullScreen = true;
    });
  }

  @override
  void onWindowLeaveFullScreen() {
    setState(() {
      _isFullScreen = false;
    });
  }
}
