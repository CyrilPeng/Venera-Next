import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:venera_next/foundation/comic_cover.dart';
import 'package:venera_next/foundation/image_provider/cached_image.dart';

CachedImageProvider? validatedComicCoverProvider(
  ComicCoverManager? manager,
  ComicCoverIdentity identity,
  ComicCoverSnapshot? snapshot,
) {
  final key = snapshot?.cacheKey;
  if (manager == null || snapshot == null || key == null) return null;
  return CachedImageProvider(
    snapshot.url,
    sourceKey: identity.sourceKey,
    cid: identity.id,
    cacheKey: key,
    onVersionMissing: () => manager.reportMissingVersion(identity, key),
  );
}

/// Retains the caller's image presentation, including Hero, loading and errors.
/// A lease exists only while this cover intersects every enclosing viewport.
class ComicCoverImage extends StatefulWidget {
  const ComicCoverImage({
    super.key,
    required this.sourceKey,
    required this.id,
    required this.url,
    required this.image,
    required this.builder,
    this.manager,
    this.enabled = true,
  });
  final String sourceKey;
  final String id;
  final String url;
  final ImageProvider image;
  final Widget Function(ImageProvider) builder;
  final ComicCoverManager? manager;
  final bool enabled;
  @override
  State<ComicCoverImage> createState() => _ComicCoverImageState();
}

class _ComicCoverImageState extends State<ComicCoverImage>
    with WidgetsBindingObserver {
  ComicCoverLease? _lease;
  ComicCoverSnapshot? _snapshot;
  final _positions = <ScrollPosition>{};
  bool _scheduled = false;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _unbindPositions();
    context.visitAncestorElements((element) {
      if (element is StatefulElement && element.state is ScrollableState) {
        final position = (element.state as ScrollableState).position;
        if (_positions.add(position)) position.addListener(_schedule);
      }
      return true;
    });
    _schedule();
  }

  @override
  void didUpdateWidget(ComicCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id ||
        oldWidget.sourceKey != widget.sourceKey ||
        oldWidget.manager != widget.manager ||
        oldWidget.enabled != widget.enabled) {
      _release();
      _snapshot = null;
    }
    _schedule();
  }

  void _schedule() {
    if (_scheduled || !mounted) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) _updateVisibility();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool _visible() {
    if (!widget.enabled ||
        !_foreground ||
        !TickerMode.valuesOf(context).enabled ||
        widget.sourceKey == 'local' ||
        widget.url.startsWith('file://')) {
      return false;
    }
    final box = context.findRenderObject();
    if (box is! RenderBox ||
        !box.attached ||
        !box.hasSize ||
        box.size.isEmpty) {
      return false;
    }
    var ancestor = box.parent;
    while (ancestor != null) {
      if (ancestor is RenderAbstractViewport) {
        final bounds = MatrixUtils.transformRect(
          box.getTransformTo(ancestor),
          Offset.zero & box.size,
        );
        if (!bounds.overlaps(ancestor.paintBounds)) return false;
      }
      ancestor = ancestor.parent;
    }
    return true;
  }

  void _updateVisibility() {
    final manager = widget.manager ?? ComicCoverManager.instance;
    if (manager == null || manager.isClosed || !_visible()) {
      _release();
      return;
    }
    if (_lease != null) return;
    _lease = manager.acquire(
      ComicCoverIdentity(widget.sourceKey, widget.id),
      widget.url,
    );
    _lease!.changes.addListener(_changed);
    _changed();
  }

  void _changed() {
    if (!mounted || _lease == null) return;
    setState(() => _snapshot = _lease!.snapshot);
  }

  void _release() {
    final lease = _lease;
    if (lease == null) return;
    _snapshot = lease.snapshot;
    lease.changes.removeListener(_changed);
    lease.release();
    _lease = null;
  }

  void _unbindPositions() {
    for (final position in _positions) {
      position.removeListener(_schedule);
    }
    _positions.clear();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _schedule();
  }

  @override
  void dispose() {
    _release();
    _unbindPositions();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _schedule();
    final identity = ComicCoverIdentity(widget.sourceKey, widget.id);
    final image =
        !widget.enabled ||
            widget.sourceKey == 'local' ||
            widget.url.startsWith('file://')
        ? widget.image
        : validatedComicCoverProvider(
                widget.manager ?? ComicCoverManager.instance,
                identity,
                _snapshot,
              ) ??
              widget.image;
    // A recycled tile can keep the previous frame only for the same comic.
    return KeyedSubtree(key: ValueKey(identity), child: widget.builder(image));
  }
}
