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
          SliverAppbar(
            leading: IconButton(
              tooltip: 'Back'.tl,
              onPressed: context.pop,
              icon: const Icon(Icons.arrow_back),
            ),
            title: Text('Reading statistics'.tl),
          ),
          SliverToBoxAdapter(
            child: Container(
              width: double.infinity,
              color: context.colorScheme.surfaceContainerLow,
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    formatReadingDuration(totalDuration),
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Total reading time'.tl,
                    style: TextStyle(
                      color: context.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _SummaryMetric(
                          label: 'Comics with reading time'.tl,
                          value: manager.countWithReadDuration().toString(),
                        ),
                      ),
                      const SizedBox(width: 24),
                      Expanded(
                        flex: 2,
                        child: _SummaryMetric(
                          label: 'Most-read comic'.tl,
                          value:
                              longestReadTitle ?? 'No reading time recorded'.tl,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
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
                  subtitle: history.subtitle.isEmpty
                      ? null
                      : Text(
                          history.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                  trailing: Text(
                    formatReadingDuration(
                      Duration(milliseconds: history.readDurationMs),
                    ),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                );
              },
            ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
        ],
      ),
    );
  }
}

class _SummaryMetric extends StatelessWidget {
  const _SummaryMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
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
