import 'dart:async';
import 'package:flutter/material.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/translations.dart';

/// Owns one selection overlay and completes its waiter on replacement/disposal.
class ReaderImageSelectionOverlay {
  OverlayEntry? _entry;
  Completer<Offset?>? _result;
  bool _disposed = false;

  Future<Offset?> show(BuildContext context) {
    if (_disposed) return Future.value(null);
    _dismiss();
    final result = _result = Completer<Offset?>();
    final entry = _entry = OverlayEntry(
      builder: (_) =>
          Positioned.fill(child: _SelectImageOverlayContent(onTap: _dismiss)),
    );
    Overlay.of(context).insert(entry);
    return result.future;
  }

  void _dismiss([Offset? location]) {
    final entry = _entry;
    final result = _result;
    _entry = null;
    _result = null;
    if (result != null && !result.isCompleted) result.complete(location);
    entry?.remove();
    entry?.dispose();
  }

  void dispose() {
    _disposed = true;
    _dismiss();
  }
}

class _SelectImageOverlayContent extends StatelessWidget {
  const _SelectImageOverlayContent({required this.onTap});
  final void Function(Offset) onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) {
        onTap(details.globalPosition);
      },
      child: Container(
        color: Colors.black.withAlpha(50),
        child: Align(
          alignment: Alignment(0, -0.8),
          child: Container(
            width: 232,
            constraints: const BoxConstraints(minHeight: 42),
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: context.colorScheme.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: context.colorScheme.outlineVariant),
            ),
            child: Row(
              children: [
                const SizedBox(width: 8),
                const Icon(Icons.info_outline),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    "Click to select an image".tl,
                    style: TextStyle(
                      fontSize: 16,
                      color: context.colorScheme.onSurface,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
