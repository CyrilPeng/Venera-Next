import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera_next/foundation/reader_diagnostics.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/components/file_save_task.dart';

/// Reports stay in this reader's memory until cleared or the reader closes.
class ReaderDiagnosticsDialog extends StatefulWidget {
  const ReaderDiagnosticsDialog({super.key, required this.diagnostics});
  final ReaderDiagnostics diagnostics;

  @override
  State<ReaderDiagnosticsDialog> createState() =>
      _ReaderDiagnosticsDialogState();
}

class _ReaderDiagnosticsDialogState extends State<ReaderDiagnosticsDialog> {
  bool _copying = false;
  bool _saving = false;
  bool get _busy => _copying || _saving;
  String? _feedback;

  Future<void> _copy(String report) async {
    setState(() => _copying = true);
    try {
      await Clipboard.setData(ClipboardData(text: report));
      if (mounted) setState(() => _feedback = 'Copied'.tl);
    } catch (_) {
      if (mounted) setState(() => _feedback = 'Unable to copy report.'.tl);
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  Future<void> _save() async {
    // Capture bytes before opening the picker. The existing save boundary
    // retains pending platform work in the original window if this dialog exits.
    final bytes = utf8.encode(widget.diagnostics.exportJson(complete: true));
    setState(() => _saving = true);
    try {
      final saved = await saveFileForWindow(
        context,
        data: bytes,
        filename: 'reader-diagnostics.json',
      );
      if (mounted && saved) setState(() => _feedback = 'Saved'.tl);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.diagnostics,
    builder: (context, _) {
      final diagnostics = widget.diagnostics;
      final report = diagnostics.hasCapture ? diagnostics.exportJson() : null;
      final lines = report?.split('\n') ?? const <String>[];
      return AlertDialog(
        title: Text('Reading diagnostics'.tl),
        scrollable: true,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        content: SizedBox(
          width: 600,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Manual capture only, up to 45 seconds. Browse existing local pages, then quickly revisit them. Open this dialog again to stop and review.'
                    .tl,
              ),
              const SizedBox(height: 12),
              Text(
                'Only numeric timings, anonymous image numbers and basic reader options are included. No comic content, titles, paths, URLs, accounts, scripts or error text. Nothing is uploaded.'
                    .tl,
              ),
              const SizedBox(height: 12),
              Text(
                'Elapsed image waits do not prove UI blocking. Frame samples are not measured FPS. Captures are cleared when the reader closes.'
                    .tl,
              ),
              const SizedBox(height: 12),
              Text(
                'Copy uses the bounded preview. Save the full report to include all retained frame and navigation samples.'
                    .tl,
              ),
              if (diagnostics.hasCapture) ...[
                const SizedBox(height: 12),
                Text(
                  diagnostics.isRecording
                      ? 'Capturing...'.tl
                      : 'Report preview'.tl,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: (MediaQuery.sizeOf(context).height * .35).clamp(
                    100,
                    280,
                  ),
                  child: Scrollbar(
                    child: ListView.builder(
                      key: const ValueKey('reader-diagnostic-preview'),
                      itemCount: lines.length,
                      itemBuilder: (context, index) => SelectableText(
                        lines[index],
                        textDirection: TextDirection.ltr,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),
                ),
              ],
              if (_feedback != null) ...[
                const SizedBox(height: 8),
                Text(_feedback!),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Close'.tl),
          ),
          if (report != null && !diagnostics.isRecording) ...[
            TextButton(
              onPressed: _busy
                  ? null
                  : () {
                      diagnostics.clear();
                      setState(() => _feedback = null);
                    },
              child: Text('Clear report'.tl),
            ),
            TextButton(
              onPressed: _busy ? null : () => _copy(report),
              child: Text('Copy report'.tl),
            ),
            TextButton(
              onPressed: _busy ? null : _save,
              child: Text('Save full report'.tl),
            ),
          ],
          if (diagnostics.isRecording)
            FilledButton(
              onPressed: () => diagnostics.stop(ReaderDiagnosticStop.review),
              child: Text('Stop and review'.tl),
            )
          else
            FilledButton(
              onPressed: _busy ? null : () => Navigator.of(context).pop(true),
              child: Text('Start new 45-second capture'.tl),
            ),
        ],
      );
    },
  );
}
