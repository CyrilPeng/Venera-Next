import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera_next/components/file_save_task.dart';
import 'package:venera_next/components/menu.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/file_type.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/foundation/translations.dart';
import 'clipboard_image.dart';
import 'gesture_port.dart';
import 'gesture_request.dart';
import 'image_action.dart';
import 'reader_tap_scope.dart';

class ReaderGestureDetector extends StatefulWidget {
  const ReaderGestureDetector({
    super.key,
    required this.imageWork,
    required this.changes,
    required this.createRequest,
    required this.onPortChanged,
    required this.isMenuOpen,
    required this.toggleMenu,
    required this.openSettings,
    required this.openChapters,
    required this.child,
  });
  final ImageWork imageWork;
  final Listenable changes;
  final ReaderGestureRequest? Function() createRequest;
  final void Function(ReaderGesturePort port, bool attached) onPortChanged;
  final bool Function() isMenuOpen;
  final VoidCallback toggleMenu, openSettings, openChapters;
  final Widget child;
  @override
  State<ReaderGestureDetector> createState() => ReaderGestureDetectorState();
}

class ReaderGestureDetectorState extends State<ReaderGestureDetector>
    implements ReaderGesturePort {
  static const _doubleTapDelay = Duration(milliseconds: 200);
  static const _longPressDelay = Duration(milliseconds: 250);
  static const _distanceSquared = 20.0 * 20.0;
  late TapGestureRecognizer _recognizer;
  final _pointers = <int>{};
  final _dragListeners = <ReaderDragListener>{};
  List<ReaderDragListener> _drag = [];
  ReaderGestureRequest? _sequence, _tapTarget;
  ({ReaderGestureRequest request, Offset global, Offset local})? _pendingTap;
  Timer? _tapTimer, _longPressTimer;
  VoidCallback? _releasePause, _releaseZoom;
  int? _primaryPointer;
  Offset _movement = Offset.zero;
  Offset _lastPosition = Offset.zero;
  bool _longPressUsed = false, _ignoreNextTap = false, _inactive = false;
  bool _disposed = false;
  int _generation = 0;
  final _contextMenus = MenuRouteController();

  bool _accepts(ReaderGestureRequest request) =>
      mounted && !_inactive && !_disposed && request.isCurrent();

  TapGestureRecognizer _createRecognizer() => TapGestureRecognizer()
    ..onTapUp = _onTapUp
    ..onSecondaryTapUp = (event) {
      final request = _tapTarget;
      _tapTarget = null;
      if (request != null && _accepts(request)) {
        _showMenu(request, event.globalPosition);
      }
    };

  @override
  void initState() {
    super.initState();
    _recognizer = _createRecognizer();
    widget.changes.addListener(_checkTarget);
    widget.onPortChanged(this, true);
  }

  @override
  void didUpdateWidget(ReaderGestureDetector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.changes, widget.changes)) {
      _contextMenus.close();
      oldWidget.changes.removeListener(_checkTarget);
      widget.changes.addListener(_checkTarget);
      _retire();
    }
    if (oldWidget.onPortChanged != widget.onPortChanged) {
      _contextMenus.close();
      oldWidget.onPortChanged(this, false);
      _retire();
      widget.onPortChanged(this, true);
    }
    if (!identical(oldWidget.imageWork, widget.imageWork)) {
      _contextMenus.close();
      _retire();
    }
    _checkTarget();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    ModalRoute.of(context);
    _checkTarget();
  }

  void _checkTarget() {
    _contextMenus.revalidate();
    if ((_sequence != null && !_accepts(_sequence!)) ||
        (_tapTarget != null && !_accepts(_tapTarget!)) ||
        (_pendingTap != null && !_accepts(_pendingTap!.request))) {
      _retire();
    }
  }

  @override
  void deactivate() {
    _inactive = true;
    _contextMenus.close();
    _retire();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _inactive = false;
  }

  @override
  void dispose() {
    _disposed = true;
    _contextMenus.dispose();
    widget.changes.removeListener(_checkTarget);
    widget.onPortChanged(this, false);
    _retire();
    _recognizer.dispose();
    _dragListeners.clear();
    super.dispose();
  }

  void _retire() {
    _generation++;
    cancelPendingTap();
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _sequence = _tapTarget = null;
    _primaryPointer = null;
    _pointers.clear();
    final releaseZoom = _releaseZoom, releasePause = _releasePause;
    _releaseZoom = _releasePause = null;
    final drag = _drag;
    _drag = [];
    _longPressUsed = false;
    _ignoreNextTap = false;
    _movement = Offset.zero;
    if (!_disposed) {
      _recognizer.dispose();
      _recognizer = _createRecognizer();
    }
    try {
      releaseZoom?.call();
    } finally {
      try {
        for (final listener in drag) {
          listener.onCancel?.call();
        }
      } finally {
        releasePause?.call();
      }
    }
  }

  @override
  void ignoreNextTap() {
    cancelPendingTap();
    _ignoreNextTap = true;
  }

  @override
  void clearIgnoreNextTap() {
    _ignoreNextTap = false;
  }

  @override
  void cancelPendingTap() {
    _tapTimer?.cancel();
    _tapTimer = null;
    _pendingTap = null;
  }

  @override
  void addDragListener(ReaderDragListener listener) {
    _dragListeners.add(listener);
  }

  @override
  void removeDragListener(ReaderDragListener listener) {
    _dragListeners.remove(listener);
  }

  void _onDown(PointerDownEvent event) {
    if (event.position == Offset.zero) {
      cancelPendingTap();
      return;
    }
    final request = widget.createRequest();
    if (request == null || !_accepts(request)) return;
    if (_sequence != null && _sequence!.identity != request.identity) _retire();
    _sequence = request;
    _pointers.add(event.pointer);
    _releasePause ??= request.acquirePause();
    if (!_accepts(request)) {
      _retire();
      return;
    }
    if (_ignoreNextTap) {
      _ignoreNextTap = false;
      return;
    }
    if (_pointers.length > 1) {
      cancelPendingTap();
      _longPressTimer?.cancel();
      _tapTarget = null;
      _primaryPointer = null;
      final releaseZoom = _releaseZoom;
      _releaseZoom = null;
      releaseZoom?.call();
      _finishDrag(cancelled: true);
      return;
    }
    _primaryPointer = event.pointer;
    _tapTarget = request;
    _movement = Offset.zero;
    _lastPosition = event.position;
    _longPressUsed = false;
    _recognizer.addPointer(event);
    _longPressTimer?.cancel();
    _longPressTimer = Timer(_longPressDelay, () {
      _longPressTimer = null;
      if (!_accepts(request)) {
        _retire();
        return;
      }
      if (_primaryPointer != event.pointer || _pointers.length != 1) return;
      cancelPendingTap();
      _longPressUsed = true;
      if (_movement.distanceSquared < _distanceSquared) {
        switch (request.preferences.longPressAction) {
          case 'zoom':
            final viewport = request.viewport;
            if (viewport != null) {
              _releaseZoom = () => viewport.handleLongPressUp(_lastPosition);
              viewport.handleLongPressDown(event.position);
            }
          case 'autoReading':
            request.toggleAutomaticReading();
        }
      } else {
        final generation = _generation;
        _drag = List.of(_dragListeners);
        for (final listener in List.of(_drag)) {
          if (generation != _generation) return;
          if (!_accepts(request)) {
            _retire();
            return;
          }
          if (!_dragListeners.contains(listener)) continue;
          listener.onStart?.call(event.position);
          if (generation == _generation &&
              _accepts(request) &&
              _dragListeners.contains(listener)) {
            listener.onMove?.call(_movement);
          }
        }
      }
    });
  }

  void _onMove(PointerMoveEvent event) {
    final request = _sequence;
    if (request == null || !_pointers.contains(event.pointer)) return;
    if (!_accepts(request)) {
      _retire();
      return;
    }
    if (event.pointer == _primaryPointer) {
      _movement += event.delta;
      _lastPosition = event.position;
    }
    for (final listener in List.of(_drag)) {
      if (!_drag.contains(listener)) continue;
      if (!_accepts(request)) {
        _retire();
        return;
      }
      if (_dragListeners.contains(listener)) listener.onMove?.call(event.delta);
    }
  }

  void _finishPointer(PointerEvent event, {required bool cancelled}) {
    if (!_pointers.remove(event.pointer)) return;
    final request = _sequence;
    if (request == null || !_accepts(request)) {
      _retire();
      return;
    }
    if (event.pointer == _primaryPointer) {
      _longPressTimer?.cancel();
      _longPressTimer = null;
      _primaryPointer = null;
      _lastPosition = event.position;
      try {
        final releaseZoom = _releaseZoom;
        _releaseZoom = null;
        releaseZoom?.call();
        _finishDrag(cancelled: cancelled || !_accepts(request));
      } finally {
        if (cancelled) {
          cancelPendingTap();
          _tapTarget = null;
        }
        _releaseCompletedPointers();
      }
    }
    _releaseCompletedPointers();
  }

  void _finishDrag({required bool cancelled}) {
    final generation = _generation;
    final request = _sequence;
    final drag = _drag;
    _drag = [];
    for (final listener in drag) {
      if (!_dragListeners.contains(listener)) continue;
      if (cancelled ||
          generation != _generation ||
          request == null ||
          !_accepts(request)) {
        listener.onCancel?.call();
      } else {
        listener.onEnd?.call();
      }
    }
  }

  void _releaseCompletedPointers() {
    if (_pointers.isEmpty) {
      final release = _releasePause;
      _releasePause = null;
      _sequence = null;
      release?.call();
    }
  }

  void _onTapUp(TapUpDetails event) {
    final request = _tapTarget;
    _tapTarget = null;
    if (request == null || !_accepts(request)) return;
    if (event.globalPosition == Offset.zero &&
        event.localPosition == Offset.zero) {
      cancelPendingTap();
      return;
    }
    if (_longPressUsed) {
      _longPressUsed = false;
      return;
    }
    final box = context.findRenderObject()! as RenderBox;
    final local = box.globalToLocal(event.globalPosition);
    if (!request.preferences.enableDoubleTapToZoom) {
      _tap(request, event.globalPosition, local);
      return;
    }
    final previous = _pendingTap;
    cancelPendingTap();
    if (previous != null && _accepts(previous.request)) {
      if (previous.request.identity == request.identity &&
          (event.globalPosition - previous.global).distanceSquared <
              _distanceSquared) {
        request.viewport?.handleDoubleTap(event.globalPosition);
        return;
      }
      _tap(previous.request, previous.global, previous.local);
    }
    if (!_accepts(request)) return;
    final pending = (
      request: request,
      global: event.globalPosition,
      local: local,
    );
    _pendingTap = pending;
    _tapTimer = Timer(_doubleTapDelay, () {
      if (_pendingTap != pending) return;
      cancelPendingTap();
      if (_accepts(request)) _tap(request, pending.global, pending.local);
    });
  }

  void _tap(ReaderGestureRequest request, Offset global, Offset local) {
    if (!_accepts(request) || request.viewport == null) return;
    if (request.viewport!.handleOnTap(global) || !_accepts(request)) return;
    if (widget.isMenuOpen()) {
      widget.toggleMenu();
      return;
    }
    if (request.onCommentsPage) return;
    if (request.preferences.enableTapToTurnPages) {
      final size = (context.findRenderObject()! as RenderBox).size;
      final coordinate = request.vertical ? local.dy : local.dx;
      final extent = request.vertical ? size.height : size.width;
      if (coordinate < extent * 0.3 || coordinate > extent * 0.7) {
        var forward = coordinate > extent * 0.7;
        if (request.reversed) forward = !forward;
        if (request.preferences.reverseTapToTurnPages) forward = !forward;
        request.turnPage(forward);
        return;
      }
    }
    widget.toggleMenu();
  }

  void _showMenu(ReaderGestureRequest request, Offset location) {
    final settings = widget.openSettings, chapters = widget.openChapters;
    void invoke(VoidCallback action) {
      if (_accepts(request)) action();
    }

    _contextMenus.show(
      context,
      location,
      [
        MenuEntry(
          icon: Icons.settings,
          text: 'Settings'.tl,
          onClick: () => invoke(settings),
        ),
        MenuEntry(
          icon: Icons.menu,
          text: 'Chapters'.tl,
          onClick: () => invoke(chapters),
        ),
        MenuEntry(
          icon: Icons.fullscreen,
          text: 'Fullscreen'.tl,
          onClick: () => invoke(request.fullscreen),
        ),
        MenuEntry(
          icon: Icons.exit_to_app,
          text: 'Exit'.tl,
          onClick: () {
            if (_accepts(request)) unawaited(request.exit());
          },
        ),
        if (App.isDesktop && request.canUseImage)
          MenuEntry(
            icon: Icons.copy,
            text: 'Copy Image'.tl,
            onClick: () =>
                unawaited(_useImage(request, location, writeImageToClipboard)),
          ),
        if (request.canUseImage)
          MenuEntry(
            icon: Icons.download_outlined,
            text: 'Save Image'.tl,
            onClick: () => unawaited(
              _useImage(request, location, (image) async {
                final filetype = detectFileType(image);
                await saveFileForWindow(
                  context,
                  filename: 'image${filetype.ext}',
                  data: image,
                );
              }),
            ),
          ),
      ],
      isValid: () =>
          mounted && !_inactive && !_disposed && request.isTargetCurrent(),
      changes: Listenable.merge([widget.changes, request.targetChanges]),
    );
  }

  Future<void> _useImage(
    ReaderGestureRequest request,
    Offset location,
    Future<void> Function(Uint8List) consume,
  ) async {
    if (!_accepts(request) ||
        !request.canUseImage ||
        request.viewport == null) {
      return;
    }
    await useReaderImage(
      work: widget.imageWork,
      read: () => request.viewport!.getImageByOffset(location),
      isCurrent: () => _accepts(request),
      consume: consume,
      onMissing: () {
        if (mounted) context.showMessage(message: 'No Image'.tl);
      },
      onError: (error) {
        if (mounted) context.showMessage(message: error.toString());
      },
    );
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: _onDown,
    onPointerMove: _onMove,
    onPointerUp: (event) => _finishPointer(event, cancelled: false),
    onPointerCancel: (event) => _finishPointer(event, cancelled: true),
    onPointerSignal: (event) {
      final request = widget.createRequest();
      if (request == null || !_accepts(request)) return;
      request.stopAutomaticReading();
      if (event is PointerScrollEvent &&
          !HardwareKeyboard.instance.isControlPressed) {
        request.turnWheel(event.scrollDelta.dy > 0);
      }
    },
    child: ReaderTapScope(ignoreNextTap: ignoreNextTap, child: widget.child),
  );
}
