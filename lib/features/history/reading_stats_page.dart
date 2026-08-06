import 'package:flutter/material.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/components/scroll.dart';
import 'package:venera_next/features/history/history_manager.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/translations.dart';

class ReadingStatsPage extends StatefulWidget {
  const ReadingStatsPage({super.key});

  @override
  State<ReadingStatsPage> createState() => _ReadingStatsPageState();
}

class _ReadingStatsPageState extends State<ReadingStatsPage> {
  @override
  void initState() {
    super.initState();
    HistoryManager().addListener(_onHistoryChanged);
  }

  @override
  void dispose() {
    HistoryManager().removeListener(_onHistoryChanged);
    super.dispose();
  }

  void _onHistoryChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final manager = HistoryManager();
    final histories = manager.getAllByReadDuration();
    final totalDuration = Duration(
      milliseconds: manager.getTotalReadDurationMs(),
    );
    final longestReadTitle = histories.isEmpty ? null : histories.first.title;

    return Scaffold(
      body: SmoothCustomScrollView(
        slivers: [
          SliverAppbar(title: Text('Reading statistics'.tl)),
          SliverToBoxAdapter(
            child: ReadingStatsSummary(
              totalDuration: totalDuration,
              comicCount: manager.countWithReadDuration(),
              mostReadTitle: longestReadTitle,
            ),
          ),
          SliverToBoxAdapter(
            child: ListTile(title: Text('Reading time by comic'.tl)),
          ),
          if (histories.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text('No reading time recorded'.tl)),
            )
          else
            SliverList.builder(
              itemCount: histories.length,
              itemBuilder: (context, index) {
                final history = histories[index];
                final duration = formatReadingDuration(
                  Duration(milliseconds: history.readDurationMs),
                );
                return LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 520;
                    final compactSubtitle = history.subtitle.isEmpty
                        ? duration
                        : '${history.subtitle} - $duration';
                    return ListTile(
                      leading: SizedBox(
                        width: 32,
                        child: Text(
                          '${index + 1}',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: context.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      title: Text(
                        history.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: compact
                          ? Text(
                              compactSubtitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            )
                          : history.subtitle.isEmpty
                          ? null
                          : Text(
                              history.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                      trailing: compact
                          ? null
                          : Text(
                              duration,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                    );
                  },
                );
              },
            ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
        ],
      ),
    );
  }
}

class ReadingStatsSummary extends StatelessWidget {
  const ReadingStatsSummary({
    super.key,
    required this.totalDuration,
    required this.comicCount,
    required this.mostReadTitle,
  });

  final Duration totalDuration;
  final int comicCount;
  final String? mostReadTitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: context.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            formatReadingDuration(totalDuration),
            style: Theme.of(
              context,
            ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            'Total reading time'.tl,
            style: TextStyle(color: context.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 560;
              final trackedComics = _SummaryMetric(
                label: 'Comics tracked'.tl,
                value: comicCount.toString(),
                compact: compact,
              );
              final mostRead = _SummaryMetric(
                label: 'Most-read comic'.tl,
                value: mostReadTitle ?? 'No reading time recorded'.tl,
                compact: compact,
              );
              if (compact) {
                return Column(
                  children: [
                    trackedComics,
                    Divider(
                      height: 1,
                      color: context.colorScheme.outlineVariant,
                    ),
                    mostRead,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: trackedComics),
                  const SizedBox(width: 32),
                  Expanded(child: mostRead),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SummaryMetric extends StatelessWidget {
  const _SummaryMetric({
    required this.label,
    required this.value,
    required this.compact,
  });

  final String label;
  final String value;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(color: context.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Text(
                value,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(color: context.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        Text(
          value,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

String formatReadingDuration(Duration duration) {
  final minutes = duration.inMinutes;
  if (duration <= Duration.zero) return '0 min'.tl;
  if (minutes == 0) return 'Less than a minute'.tl;

  final hours = duration.inHours;
  if (hours == 0) {
    return '@minutes min'.tlParams({'minutes': minutes});
  }
  return '@hours h @minutes min'.tlParams({
    'hours': hours,
    'minutes': minutes.remainder(60),
  });
}
