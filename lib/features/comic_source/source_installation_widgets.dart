import 'package:flutter/material.dart';
import 'package:venera_next/components/pop_up_widget.dart';
import 'package:venera_next/foundation/translations.dart';

import 'comic_source_manager.dart';
import 'source_installation.dart';

/// A persistent entry point, shared by the manager page and every catalog.
class SourceInstallationSummary extends StatelessWidget {
  const SourceInstallationSummary({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final queue = SourceInstallations.instance;
    return ListenableBuilder(
      listenable: queue,
      builder: (context, _) {
        final parts = <String>[
          if (queue.activeCount > 0)
            '@count in progress'.tlParams({'count': queue.activeCount}),
          if (queue.failureCount > 0)
            '@count failed'.tlParams({'count': queue.failureCount}),
          if (queue.tasks.isNotEmpty &&
              queue.activeCount == 0 &&
              queue.failureCount == 0)
            'View installation results'.tl,
        ];
        if (compact) {
          final count = queue.activeCount > 0
              ? queue.activeCount
              : queue.failureCount;
          // A permanent toolbar entry keeps the catalog in place when the
          // first task starts or finished tasks are cleared.
          return IconButton(
            tooltip: ['Installation tasks'.tl, ...parts].join(' · '),
            onPressed: () =>
                showPopUpWidget(context, const SourceInstallationPage()),
            icon: Badge.count(
              count: count,
              isLabelVisible: count > 0,
              child: const Icon(Icons.downloading_outlined),
            ),
          );
        }
        if (queue.tasks.isEmpty) return const SizedBox.shrink();
        return Material(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: ListTile(
            dense: true,
            leading: Icon(
              queue.activeCount > 0
                  ? Icons.downloading_outlined
                  : queue.failureCount > 0
                  ? Icons.error_outline
                  : Icons.download_done_outlined,
            ),
            title: Text('Installation tasks'.tl),
            subtitle: Text(parts.join(' · ')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () =>
                showPopUpWidget(context, const SourceInstallationPage()),
          ),
        );
      },
    );
  }
}

class SourceInstallationPage extends StatelessWidget {
  const SourceInstallationPage({super.key});

  @override
  Widget build(BuildContext context) {
    final queue = SourceInstallations.instance;
    return PopUpWidgetScaffold(
      title: 'Installation tasks'.tl,
      body: ListenableBuilder(
        listenable: Listenable.merge([queue, ComicSourceManager()]),
        builder: (context, _) {
          final tasks = queue.tasks;
          // Keep stable insertion order while tasks change state.
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'You can keep browsing while sources install. Tasks continue until you quit the app.'
                    .tl,
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: tasks.any((t) => !t.active)
                      ? queue.clearFinished
                      : null,
                  icon: const Icon(Icons.clear_all),
                  label: Text('Clear finished tasks'.tl),
                ),
              ),
              if (tasks.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32),
                  child: Center(child: Text('No installation tasks'.tl)),
                ),
              for (final task in tasks)
                Card.outlined(
                  key: ValueKey(task.id),
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          task.name,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          task.originLabel,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 8),
                        SourceInstallationStatus(
                          task: task,
                          showFullError: true,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Shown in both catalog rows and the task list; never captures a page callback.
class SourceInstallationStatus extends StatelessWidget {
  const SourceInstallationStatus({
    super.key,
    required this.task,
    this.showFullError = false,
    this.originLabel,
  });
  final SourceInstallTask task;
  final bool showFullError;
  final String? originLabel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final failed = task.phase == SourceInstallPhase.failed;
    final details = [
      task.statusLabel,
      ?originLabel,
      if (failed && task.errorSummary != null) task.errorSummary!,
    ].join('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SourceInstallationRow(
          text: task.statusLabel,
          label: details,
          color: failed ? colors.error : colors.primary,
          action: _SourceInstallationAction(
            task: task,
            showDetails: !showFullError,
          ),
        ),
        if (showFullError && failed && task.error != null) ...[
          const SizedBox(height: 8),
          Text(
            task.errorSummary ?? task.error!,
            style: TextStyle(color: colors.error),
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(
              'View details'.tl,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: SelectableText(
                  task.error!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Reserve the same footer for every installation state. Source metadata can
/// determine an entry's height, but changing task state must never change it.
class SourceInstallationRow extends StatelessWidget {
  const SourceInstallationRow({
    super.key,
    required this.text,
    required this.action,
    this.label,
    this.color,
  });

  final String text;
  final String? label;
  final Color? color;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall!;
    final height = (MediaQuery.textScalerOf(context).scale(14) * 1.5 + 16)
        .clamp(48.0, double.infinity);
    return SizedBox(
      height: height,
      child: Row(
        children: [
          Expanded(
            child: Tooltip(
              message: label ?? text,
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style.copyWith(color: color),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 144,
            child: Align(alignment: Alignment.centerRight, child: action),
          ),
        ],
      ),
    );
  }
}

class _SourceInstallationAction extends StatelessWidget {
  const _SourceInstallationAction({
    required this.task,
    required this.showDetails,
  });

  final SourceInstallTask task;
  final bool showDetails;

  @override
  Widget build(BuildContext context) {
    final queue = SourceInstallations.instance;
    final colors = Theme.of(context).colorScheme;
    if (task.active) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 48,
            child: Center(
              child: SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  strokeCap: StrokeCap.round,
                  backgroundColor: colors.surfaceContainerHighest,
                  value: switch (task.phase) {
                    SourceInstallPhase.downloading => task.progress,
                    SourceInstallPhase.queued => 0,
                    _ => null,
                  },
                  semanticsLabel: '${task.name} · ${task.statusLabel}',
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Cancel'.tl,
            onPressed: task.canCancel ? () => queue.cancel(task) : null,
            icon: const Icon(Icons.close, size: 20),
            constraints: const BoxConstraints.tightFor(width: 48, height: 48),
          ),
        ],
      );
    }
    final failed = task.phase == SourceInstallPhase.failed;
    final retryLabel = (failed ? 'Retry' : 'Install again').tl;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (failed && showDetails)
          IconButton(
            tooltip: 'View details'.tl,
            onPressed: () =>
                showPopUpWidget(context, const SourceInstallationPage()),
            icon: Icon(Icons.info_outline, color: colors.error, size: 20),
            constraints: const BoxConstraints.tightFor(width: 48, height: 48),
          ),
        if (queue.canRetry(task))
          Flexible(
            child: Tooltip(
              message: retryLabel,
              child: TextButton(
                onPressed: () => queue.retry(task),
                child: Text(
                  retryLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
