import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

/// Observes the list through public Flutter positions and published item bounds.
/// The sole live list is available before its first item bounds are published.
/// A distant item animation mounts two lists; published geometry then selects
/// the owner of pixel scrolling and reader image visibility.
class ContinuousScrollController extends ScrollController {
  ContinuousScrollController(this.items, {required this.onPositionChanged})
    : super(keepScrollOffset: false) {
    items.addListener(syncPosition);
  }

  final ValueListenable<Iterable<ItemPosition>> items;
  final VoidCallback onPositionChanged;
  final _anchors = <_ContinuousScrollAnchorState>{};
  bool _scheduled = false;
  bool _disposed = false;

  void _register(_ContinuousScrollAnchorState anchor) {
    _anchors.add(anchor);
    _scheduleSync();
  }

  void _unregister(_ContinuousScrollAnchorState anchor) {
    _anchors.remove(anchor);
    _scheduleSync();
  }

  void _scheduleSync() {
    if (_disposed || _scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      syncPosition();
    }, debugLabel: 'reader continuous scroll position');
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void syncPosition() {
    if (_disposed) return;
    final expected = {for (final item in items.value) item.index: item};
    final matches = <ScrollPosition, int>{};
    final live = <ScrollPosition>{};
    for (final anchor in _anchors) {
      if (!anchor.mounted) continue;
      final scroll = Scrollable.maybeOf(anchor.context)?.position;
      if (scroll == null) continue;
      live.add(scroll);
      final item = expected[anchor.widget.index];
      if (item == null || !scroll.hasContentDimensions) continue;
      final box = anchor.context.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final RenderObject? viewport = RenderAbstractViewport.maybeOf(box);
      if (viewport is! RenderBox || !viewport.hasSize) continue;
      final bounds = MatrixUtils.transformRect(
        box.getTransformTo(viewport),
        Offset.zero & box.size,
      );
      final vertical =
          axisDirectionToAxis(scroll.axisDirection) == Axis.vertical;
      final extent = vertical ? viewport.size.height : viewport.size.width;
      if (!bounds.isFinite || extent <= 0) continue;
      var leading = (vertical ? bounds.top : bounds.left) / extent;
      var trailing = (vertical ? bounds.bottom : bounds.right) / extent;
      if (axisDirectionIsReversed(scroll.axisDirection)) {
        (leading, trailing) = (1 - trailing, 1 - leading);
      }
      if ((leading - item.itemLeadingEdge).abs() < 0.0001 &&
          (trailing - item.itemTrailingEdge).abs() < 0.0001) {
        matches.update(scroll, (count) => count + 1, ifAbsent: () => 1);
      }
    }
    final current = hasClients ? position : null;
    var selected = current;
    var best = matches[current] ?? 0;
    for (final entry in matches.entries) {
      if (entry.value > best) {
        selected = entry.key;
        best = entry.value;
      }
    }
    if (selected != null && !live.contains(selected)) selected = null;
    // Item positions arrive after layout. A single live list has unambiguous
    // ownership even before that notification; two animated lists do not.
    if (selected == null && live.length == 1) selected = live.single;
    if (identical(selected, current)) return;
    if (current != null) detach(current);
    if (selected != null) attach(selected);
    onPositionChanged();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    items.removeListener(syncPosition);
    _anchors.clear();
    for (final position in positions.toList()) {
      detach(position);
    }
    // The official list owns the positions. Retire only our subscriptions.
    super.dispose();
  }
}

class ContinuousScrollAnchor extends StatefulWidget {
  const ContinuousScrollAnchor({
    super.key,
    required this.controller,
    required this.index,
    required this.child,
  });

  final ContinuousScrollController controller;
  final int index;
  final Widget child;

  @override
  State<ContinuousScrollAnchor> createState() => _ContinuousScrollAnchorState();
}

class _ContinuousScrollAnchorState extends State<ContinuousScrollAnchor> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    Scrollable.maybeOf(context);
    widget.controller._register(this);
  }

  @override
  void didUpdateWidget(ContinuousScrollAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller._unregister(this);
    }
    widget.controller._register(this);
  }

  @override
  void dispose() {
    widget.controller._unregister(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
