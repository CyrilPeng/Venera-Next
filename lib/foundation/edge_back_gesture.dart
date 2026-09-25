import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// A single-finger back swipe starting at the leading edge of this widget.
/// Deltas and velocity are normalized to the widget width, toward its trailing edge.
class EdgeBackGestureDetector extends StatelessWidget {
  const EdgeBackGestureDetector({
    super.key,
    required this.child,
    required this.enabled,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
    required this.onCancel,
    this.edgeWidth = 24,
  });

  final Widget child;
  final bool Function() enabled;
  final VoidCallback onStart;
  final ValueChanged<double> onUpdate;
  final ValueChanged<double> onEnd;
  final VoidCallback onCancel;
  final double edgeWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final direction = Directionality.of(context) == TextDirection.ltr
            ? 1.0
            : -1.0;
        final width = constraints.maxWidth;
        return RawGestureDetector(
          behavior: HitTestBehavior.translucent,
          gestures: {
            _EdgeBackRecognizer:
                GestureRecognizerFactoryWithHandlers<_EdgeBackRecognizer>(
                  () => _EdgeBackRecognizer(),
                  (recognizer) => recognizer
                    ..enabled = enabled
                    ..width = width
                    ..edgeWidth = edgeWidth
                    ..direction = direction
                    ..onStart = onStart
                    ..onUpdate = ((delta) => onUpdate(delta / width))
                    ..onEnd = ((velocity) => onEnd(velocity / width))
                    ..onCancel = onCancel,
                ),
          },
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              child,
              if (enabled())
                PositionedDirectional(
                  start: 0,
                  top: 0,
                  bottom: 0,
                  width: edgeWidth,
                  // Reserve only the edge strip, so horizontal lists cannot win
                  // before the intentional back-swipe threshold is reached.
                  child: const Listener(
                    behavior: HitTestBehavior.opaque,
                    child: SizedBox.expand(),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _EdgeBackRecognizer extends OneSequenceGestureRecognizer {
  late bool Function() enabled;
  late double width, edgeWidth, direction;
  late VoidCallback onStart, onCancel;
  late ValueChanged<double> onUpdate, onEnd;

  final _pointers = <int>{};
  int? _candidate;
  Offset _start = Offset.zero;
  Offset _delta = Offset.zero;
  VelocityTracker? _velocity;
  bool _won = false;
  bool _thresholdMet = false;
  bool _started = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _pointers.add(event.pointer);
    if (_pointers.length > 1) {
      _cancel();
      resolve(GestureDisposition.rejected);
      return;
    }
    final x = event.localPosition.dx;
    final distanceFromEdge = direction > 0 ? x : width - x;
    if (!enabled() ||
        !width.isFinite ||
        width <= 0 ||
        distanceFromEdge < 0 ||
        distanceFromEdge > edgeWidth ||
        event.buttons != kPrimaryButton) {
      resolvePointer(event.pointer, GestureDisposition.rejected);
      return;
    }
    _candidate = event.pointer;
    _start = event.localPosition;
    _delta = Offset.zero;
    _velocity = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.localPosition);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer == _candidate) {
      _velocity?.addPosition(event.timeStamp, event.localPosition);
      if (event is PointerMoveEvent) {
        _delta = event.localPosition - _start;
        if (!_started) {
          if (_delta.distance < 24) return;
          if (!enabled() ||
              _delta.dx * direction <= 0 ||
              _delta.dx.abs() < _delta.dy.abs() * 2) {
            _cancel();
            resolvePointer(event.pointer, GestureDisposition.rejected);
            return;
          }
          _thresholdMet = true;
          resolvePointer(event.pointer, GestureDisposition.accepted);
          _begin();
        } else {
          onUpdate(event.localDelta.dx * direction);
        }
      } else if (event is PointerUpEvent) {
        if (_started) {
          onEnd((_velocity?.getVelocity().pixelsPerSecond.dx ?? 0) * direction);
        }
        _clear();
      } else if (event is PointerCancelEvent) {
        _cancel();
      }
    }
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      resolvePointer(event.pointer, GestureDisposition.rejected);
      _pointers.remove(event.pointer);
      stopTrackingPointer(event.pointer);
    }
  }

  void _begin() {
    if (_won && _thresholdMet && !_started && _candidate != null) {
      _started = true;
      onStart();
      onUpdate(_delta.dx * direction);
    }
  }

  void _clear() {
    _candidate = null;
    _velocity = null;
    _started = _won = _thresholdMet = false;
  }

  void _cancel() {
    final started = _started;
    _clear();
    if (started) onCancel();
  }

  @override
  void acceptGesture(int pointer) {
    if (pointer != _candidate) return;
    _won = true;
    _begin();
  }

  @override
  void rejectGesture(int pointer) {
    if (pointer == _candidate) _cancel();
  }

  @override
  void didStopTrackingLastPointer(int pointer) => _clear();

  @override
  String get debugDescription => 'edge back swipe';
}
