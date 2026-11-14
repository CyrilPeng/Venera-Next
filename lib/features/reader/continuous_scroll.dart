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
  ContinuousScrollController(
    this.items, {
    required this.onPositionChanged,
    this.canAnchor,
  }) : super(keepScrollOffset: false) {
    items.addListener(syncPosition);
  }

  final ValueListenable<Iterable<ItemPosition>> items;
  final VoidCallback onPositionChanged;
  final bool Function(int index)? canAnchor;
  final _anchors = <_ContinuousScrollAnchorState>{};
  bool _scheduled = false;
  bool _disposed = false;
  bool _layoutChanged = false;
  ({
    _ContinuousScrollAnchorState item,
    ScrollPosition position,
    RenderBox viewport,
    double leading,
    double pixels,
    double extent,
  })?
  _layoutAnchor;

  void resetLayoutAnchor() {
    _layoutAnchor = null;
    _layoutChanged = false;
  }

  void _onExtentChanged(ScrollPosition? owner) {
    final anchor = _layoutAnchor;
    if (_disposed ||
        anchor == null ||
        !identical(owner, anchor.position) ||
        !anchor.position.hasPixels) {
      return;
    }
    _layoutChanged = true;
    // Reconcile even when multiple image resizes leave total extent unchanged.
    // The viewport will apply the correction in its own layout retry.
    anchor.position.correctBy(0);
  }

  ({RenderBox viewport, double leading, double trailing, double extent})?
  _geometry(_ContinuousScrollAnchorState anchor, ScrollPosition position) {
    if (!anchor.mounted) return null;
    final box = anchor.context.findRenderObject();
    if (box is! _RenderAnchorLayout ||
        !box.attached ||
        box.previousSize == null) {
      return null;
    }
    final RenderObject? viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport is! RenderBox || !viewport.hasSize) return null;
    // During layout a reversed sliver cannot read the child's paint transform
    // before every box has a valid size. Its public layout offset is available.
    RenderBox item = box;
    while (item.parent is RenderBox) {
      item = item.parent! as RenderBox;
    }
    final sliver = item.parent;
    if (sliver is! RenderSliverMultiBoxAdaptor || sliver.geometry == null) {
      return null;
    }
    final offset = sliver.childScrollOffset(item);
    if (offset == null) return null;
    final size = box.previousSize!;
    final vertical = sliver.constraints.axis == Axis.vertical;
    var leading = offset - sliver.constraints.scrollOffset;
    final direction = applyGrowthDirectionToAxisDirection(
      sliver.constraints.axisDirection,
      sliver.constraints.growthDirection,
    );
    if (axisDirectionIsReversed(direction)) {
      leading =
          sliver.geometry!.paintExtent -
          leading -
          (vertical ? size.height : size.width);
    }
    final bounds = MatrixUtils.transformRect(
      sliver.getTransformTo(viewport),
      (vertical ? Offset(0, leading) : Offset(leading, 0)) & size,
    );
    if (!bounds.isFinite) return null;
    final extent = vertical ? viewport.size.height : viewport.size.width;
    final reversed = axisDirectionIsReversed(position.axisDirection);
    return (
      viewport: viewport,
      extent: extent,
      leading: reversed
          ? extent - (vertical ? bounds.bottom : bounds.right)
          : (vertical ? bounds.top : bounds.left),
      trailing: reversed
          ? extent - (vertical ? bounds.top : bounds.left)
          : (vertical ? bounds.bottom : bounds.right),
    );
  }

  void _captureLayoutAnchor(ScrollPosition? position) {
    resetLayoutAnchor();
    if (position == null) return;
    for (final anchor in _anchors) {
      if (!anchor.mounted ||
          anchor.widget.index <= 0 ||
          canAnchor?.call(anchor.widget.index) == false ||
          !identical(Scrollable.maybeOf(anchor.context)?.position, position)) {
        continue;
      }
      final geometry = _geometry(anchor, position);
      if (geometry == null ||
          geometry.trailing <= 0 ||
          geometry.leading >= geometry.extent ||
          (_layoutAnchor != null &&
              _layoutAnchor!.item.widget.index < anchor.widget.index)) {
        continue;
      }
      _layoutAnchor = (
        item: anchor,
        position: position,
        viewport: geometry.viewport,
        leading: geometry.leading,
        pixels: position.pixels,
        extent: geometry.extent,
      );
    }
  }

  double? _correctLayout(ScrollMetrics metrics) {
    if (!_layoutChanged) return null;
    _layoutChanged = false;
    final anchor = _layoutAnchor;
    if (anchor == null ||
        !hasClients ||
        !identical(position, anchor.position) ||
        metrics.viewportDimension != anchor.extent) {
      return null;
    }
    final geometry = _geometry(anchor.item, anchor.position);
    if (geometry == null || !identical(geometry.viewport, anchor.viewport)) {
      return null;
    }
    // Preserve the item's position while accounting for real user/fling travel
    // since the previous frame. No jumpTo, which would cancel that activity.
    final correction =
        geometry.leading - anchor.leading + metrics.pixels - anchor.pixels;
    if (!correction.isFinite || correction.abs() < 0.01) return null;
    return (metrics.pixels + correction).clamp(
      metrics.minScrollExtent,
      metrics.maxScrollExtent,
    );
  }

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
    _captureLayoutAnchor(selected);
    if (identical(selected, current)) return;
    if (current != null) detach(current);
    if (selected != null) attach(selected);
    onPositionChanged();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    resetLayoutAnchor();
    items.removeListener(syncPosition);
    _anchors.clear();
    for (final position in positions.toList()) {
      detach(position);
    }
    // The official list owns the positions. Retire only our subscriptions.
    super.dispose();
  }
}

/// Correct asynchronous item resizing before the viewport paints its frame.
class ContinuousLayoutPhysics extends ScrollPhysics {
  const ContinuousLayoutPhysics({required this.controller, super.parent});

  final ContinuousScrollController controller;

  @override
  ContinuousLayoutPhysics applyTo(ScrollPhysics? ancestor) =>
      ContinuousLayoutPhysics(
        controller: controller,
        parent: buildParent(ancestor),
      );

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) =>
      controller._correctLayout(newPosition) ??
      super.adjustPositionForNewDimensions(
        oldPosition: oldPosition,
        newPosition: newPosition,
        isScrolling: isScrolling,
        velocity: velocity,
      );
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
  Widget build(BuildContext context) =>
      _AnchorLayout(controller: widget.controller, child: widget.child);
}

class _AnchorLayout extends SingleChildRenderObjectWidget {
  const _AnchorLayout({required this.controller, required super.child});
  final ContinuousScrollController controller;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderAnchorLayout(controller, Scrollable.maybeOf(context)?.position);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderAnchorLayout renderObject,
  ) {
    renderObject.controller = controller;
    renderObject.position = Scrollable.maybeOf(context)?.position;
  }
}

class _RenderAnchorLayout extends RenderProxyBox {
  _RenderAnchorLayout(this.controller, this.position);
  ContinuousScrollController controller;
  ScrollPosition? position;
  Size? previousSize;

  @override
  void performLayout() {
    super.performLayout();
    if (previousSize != null && previousSize != size) {
      controller._onExtentChanged(position);
    }
    previousSize = size;
  }
}
