import 'package:venera_next/features/history/history_api.dart';
import 'package:flutter/material.dart';
import 'package:venera_next/components/gesture.dart';
import 'package:venera_next/components/summary_header.dart';
import 'package:venera_next/features/comic_details/comic_details.dart';
import 'package:venera_next/features/comic_widgets/comic_widgets.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

import 'history_manager.dart';
import 'history_page.dart';

class HistorySummary extends StatefulWidget {
  const HistorySummary({
    super.key,
    required this.manager,
    required this.favoriteChanges,
  });

  final HistoryManager? manager;
  final Listenable? favoriteChanges;

  @override
  State<HistorySummary> createState() => _HistorySummaryState();
}

class _HistorySummaryState extends State<HistorySummary> {
  late Listenable _changes;
  List<History> _history = const [];
  int _count = 0;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  void _bind() {
    _changes = Listenable.merge([widget.manager, widget.favoriteChanges]);
    _changes.addListener(_changed);
    _refresh();
  }

  // Preserve notification-driven queries; theme/layout builds reuse the data.
  void _refresh() {
    final owner = widget.manager;
    if (owner == null || !owner.isInitialized) {
      _history = const [];
      _count = 0;
      return;
    }
    final recent = owner.getRecent();
    final count = owner.count();
    _history = recent;
    _count = count;
  }

  void _changed() {
    if (mounted) setState(_refresh);
  }

  @override
  void didUpdateWidget(covariant HistorySummary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.manager, widget.manager) &&
        identical(oldWidget.favoriteChanges, widget.favoriteChanges)) {
      return;
    }
    _changes.removeListener(_changed);
    _bind();
  }

  @override
  void dispose() {
    _changes.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = widget.manager?.isInitialized == true;
    return _buildSummary(
      context,
      ready ? _history : const [],
      ready ? _count : 0,
    );
  }

  Widget _buildSummary(BuildContext context, List<History> history, int count) {
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 0.6,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: ClickInkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            context.to(() => const HistoryPage());
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SummaryHeader(title: 'History'.tl, count: count),
              if (history.isNotEmpty)
                SizedBox(
                  height: 136,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: history.length,
                    itemBuilder: (context, index) {
                      final heroID = history[index].id.hashCode;
                      return SimpleComicTile(
                        comic: history[index],
                        heroID: heroID,
                        gaplessPlayback: true,
                        onTap: () {
                          context.to(
                            () => ComicPage(
                              id: history[index].id,
                              sourceKey: history[index].type.sourceKey,
                              cover: history[index].cover,
                              title: history[index].title,
                              heroID: heroID,
                            ),
                          );
                        },
                      ).paddingHorizontal(8).paddingVertical(2);
                    },
                  ),
                ).paddingHorizontal(8).paddingBottom(16),
            ],
          ),
        ),
      ),
    );
  }
}
