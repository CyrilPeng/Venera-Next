import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:venera_next/components/gesture.dart';
import 'package:venera_next/foundation/translations.dart';

import 'chapter_menu.dart';

/// Chapter presentation has no reader, manager or Navigator dependency.
class ReaderChaptersView extends StatelessWidget {
  const ReaderChaptersView({
    super.key,
    required this.data,
    required this.onSelect,
    required this.onClose,
  });
  final ReaderChapterMenuData data;
  final ValueChanged<int> onSelect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => DefaultTabController(
    key: ObjectKey(data),
    length: data.groups.length,
    initialIndex: data.initialGroup,
    animationDuration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 200),
    child: _ChapterMenuBody(data: data, onSelect: onSelect, onClose: onClose),
  );
}

class _ChapterMenuBody extends StatefulWidget {
  const _ChapterMenuBody({
    required this.data,
    required this.onSelect,
    required this.onClose,
  });
  final ReaderChapterMenuData data;
  final ValueChanged<int> onSelect;
  final VoidCallback onClose;
  @override
  State<_ChapterMenuBody> createState() => _ChapterMenuBodyState();
}

class _ChapterMenuBodyState extends State<_ChapterMenuBody> {
  bool _descending = false;
  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final colors = Theme.of(context).colorScheme;
    final textScale = MediaQuery.textScalerOf(context);
    return Material(
      color: colors.surface,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Back'.tl,
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.arrow_back),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Chapters'.tl,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ],
              ),
            ),
            if (!data.isGrouped)
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextButton.icon(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    icon: Icon(
                      _descending ? Icons.arrow_downward : Icons.arrow_upward,
                    ),
                    label: Text(_descending ? 'Descending'.tl : 'Ascending'.tl),
                    onPressed: () => setState(() => _descending = !_descending),
                  ),
                ),
              ),
            if (data.isGrouped && data.groups.isNotEmpty)
              TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  for (final group in data.groups)
                    Tab(
                      height: math.max(48, textScale.scale(16) * 1.4 + 16),
                      child: Text(
                        group.name!,
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
                ],
              ),
            const Divider(height: 1),
            Expanded(
              child: data.groups.isEmpty
                  ? _empty()
                  : TabBarView(
                      children: [
                        for (var i = 0; i < data.groups.length; i++)
                          _ChapterList(
                            key: ValueKey((i, _descending)),
                            group: data.groups[i],
                            currentChapter: data.currentChapter,
                            descending: _descending,
                            onSelect: widget.onSelect,
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _empty() => Center(
  child: Padding(padding: const EdgeInsets.all(16), child: Text('No data'.tl)),
);

/// Anchor the current item using two lazy slivers instead of estimating pixel
/// offsets from a fixed row height. Earlier rows grow upward from the anchor.
class _ChapterList extends StatefulWidget {
  const _ChapterList({
    super.key,
    required this.group,
    required this.currentChapter,
    required this.descending,
    required this.onSelect,
  });
  final ReaderChapterGroup group;
  final int currentChapter;
  final bool descending;
  final ValueChanged<int> onSelect;
  @override
  State<_ChapterList> createState() => _ChapterListState();
}

class _ChapterListState extends State<_ChapterList> {
  final _center = GlobalKey();
  late final _controller = _ChapterScrollController(() {
    final sliver = _center.currentContext?.findRenderObject() as RenderSliver?;
    return sliver?.geometry?.scrollExtent;
  });
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.group.entries;
    if (entries.isEmpty) return _empty();
    ReaderChapterEntry at(int index) =>
        entries[widget.descending ? entries.length - 1 - index : index];
    var pivot = entries.indexWhere(
      (entry) => entry.index == widget.currentChapter,
    );
    if (pivot < 0) pivot = widget.descending ? entries.length - 1 : 0;
    if (widget.descending) pivot = entries.length - 1 - pivot;
    Widget tile(int displayIndex) {
      final entry = at(displayIndex);
      return IndexedSemantics(
        index: displayIndex,
        child: _ChapterListTile(
          key: ValueKey(entry.index),
          entry: entry,
          active: entry.index == widget.currentChapter,
          onTap: () => widget.onSelect(entry.index),
        ),
      );
    }

    return Scrollbar(
      controller: _controller,
      child: CustomScrollView(
        controller: _controller,
        center: _center,
        semanticChildCount: entries.length,
        slivers: [
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (_, index) => tile(pivot - 1 - index),
              childCount: pivot,
              addSemanticIndexes: false,
            ),
          ),
          SliverList(
            key: _center,
            delegate: SliverChildBuilderDelegate(
              (_, index) => tile(pivot + index),
              childCount: entries.length - pivot,
              addSemanticIndexes: false,
            ),
          ),
        ],
      ),
    );
  }
}

/// A centered viewport normally permits offset zero even when its trailing
/// sliver is shorter than the viewport. Bound that empty range during layout:
/// the final chapter fills from the bottom and short lists cannot overscroll.
class _ChapterScrollController extends ScrollController {
  _ChapterScrollController(this.trailingExtent);
  final double? Function() trailingExtent;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _ChapterScrollPosition(
    physics: physics,
    context: context,
    oldPosition: oldPosition,
    trailingExtent: trailingExtent,
  );
}

class _ChapterScrollPosition extends ScrollPositionWithSingleContext {
  _ChapterScrollPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
    required this.trailingExtent,
  });
  final double? Function() trailingExtent;

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final extent = trailingExtent();
    if (extent != null && hasViewportDimension) {
      maxScrollExtent = math.max(
        minScrollExtent,
        math.min(maxScrollExtent, extent - viewportDimension),
      );
    }
    return super.applyContentDimensions(minScrollExtent, maxScrollExtent);
  }
}

class _ChapterListTile extends StatelessWidget {
  const _ChapterListTile({
    super.key,
    required this.entry,
    required this.active,
    required this.onTap,
  });
  final ReaderChapterEntry entry;
  final bool active;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return MergeSemantics(
      child: Semantics(
        button: true,
        selected: active,
        child: ClickInkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              border: BorderDirectional(
                start: BorderSide(
                  width: 4,
                  color: active ? colors.primary : Colors.transparent,
                ),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    entry.title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: active ? FontWeight.bold : FontWeight.normal,
                      color: active ? colors.primary : colors.onSurface,
                    ),
                  ),
                ),
                if (entry.downloaded) ...[
                  const SizedBox(width: 12),
                  Padding(
                    padding: EdgeInsets.only(
                      top: math.max(
                        0,
                        (MediaQuery.textScalerOf(context).scale(16) * 1.2 -
                                24) /
                            2,
                      ),
                    ),
                    child: Icon(
                      Icons.download_done_rounded,
                      color: colors.secondary,
                      semanticLabel: 'Chapter downloaded'.tl,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
