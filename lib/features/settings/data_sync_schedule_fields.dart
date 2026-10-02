import 'package:flutter/material.dart';
import 'package:venera_next/foundation/sync_configuration.dart';
import 'package:venera_next/foundation/translations.dart';

class DataSyncScheduleFields extends StatelessWidget {
  const DataSyncScheduleFields({
    super.key,
    required this.mode,
    required this.minutes,
    required this.onModeChanged,
    required this.onIntervalChanged,
  });

  final DataSyncMode mode;
  final int minutes;
  final ValueChanged<DataSyncMode> onModeChanged;
  final ValueChanged<int> onIntervalChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InputDecorator(
          decoration: InputDecoration(
            labelText: 'Sync mode'.tl,
            border: const OutlineInputBorder(),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<DataSyncMode>(
              isExpanded: true,
              value: mode,
              items: [
                DropdownMenuItem(
                  value: DataSyncMode.manual,
                  child: Text('Manual sync'.tl),
                ),
                DropdownMenuItem(
                  value: DataSyncMode.realtime,
                  child: Text('Real-time sync'.tl),
                ),
                DropdownMenuItem(
                  value: DataSyncMode.scheduled,
                  child: Text('Scheduled sync'.tl),
                ),
              ],
              onChanged: (value) {
                if (value != null) onModeChanged(value);
              },
            ),
          ),
        ),
        if (mode == DataSyncMode.scheduled) ...[
          const SizedBox(height: 16),
          InputDecorator(
            decoration: InputDecoration(
              labelText: 'Sync interval'.tl,
              border: const OutlineInputBorder(),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                isExpanded: true,
                value: minutes,
                items: [
                  for (final interval in SyncConfiguration.intervalOptions)
                    DropdownMenuItem(
                      value: interval,
                      child: Text(
                        '@minutes min'.tlParams({'minutes': '$interval'}),
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) onIntervalChanged(value);
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Syncs at the selected interval while the app is running. Overdue syncs run when the app reopens. Local changes are uploaded; otherwise, the server is checked for updates.'
                .tl,
          ),
        ],
      ],
    );
  }
}
