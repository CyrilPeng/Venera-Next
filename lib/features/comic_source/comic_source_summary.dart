import 'package:flutter/material.dart';
import 'package:venera_next/components/gesture.dart';
import 'package:venera_next/components/summary_header.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

import 'comic_source_manager.dart';
import 'comic_source_page.dart';
import 'source_summary_snapshot.dart';

class ComicSourceSummary extends StatelessWidget {
  const ComicSourceSummary({super.key, required this.manager});

  final ComicSourceManager? manager;

  @override
  Widget build(BuildContext context) {
    final owner = manager;
    if (owner == null || owner.isClosing) {
      return _buildSummary(context, const ComicSourceSummarySnapshot.empty());
    }
    return ListenableBuilder(
      listenable: owner,
      builder: (context, _) => _buildSummary(
        context,
        ComicSourceSummarySnapshot.fromSources(
          owner.all(),
          owner.availableUpdates,
        ),
      ),
    );
  }

  Widget _buildSummary(
    BuildContext context,
    ComicSourceSummarySnapshot snapshot,
  ) {
    final comicSources = snapshot.names;
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
            context.to(() => const ComicSourcePage());
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SummaryHeader(
                title: 'Comic Source'.tl,
                count: comicSources.length,
              ),
              if (comicSources.isNotEmpty)
                SizedBox(
                  width: double.infinity,
                  child: Wrap(
                    runSpacing: 8,
                    spacing: 8,
                    children: comicSources.map((e) {
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(e),
                      );
                    }).toList(),
                  ).paddingHorizontal(16).paddingBottom(16),
                ),
              if (snapshot.availableUpdates > 0)
                Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: context.colorScheme.outlineVariant,
                          width: 0.6,
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.update,
                            color: context.colorScheme.primary,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            "@c updates".tlParams({
                              'c': snapshot.availableUpdates,
                            }),
                            style: ts.withColor(context.colorScheme.primary),
                          ),
                        ],
                      ),
                    )
                    .toAlign(Alignment.centerLeft)
                    .paddingHorizontal(16)
                    .paddingBottom(8),
            ],
          ),
        ),
      ),
    );
  }
}
