import 'package:venera_next/foundation/application_preferences.dart';

/// One captured retention edit. Saving and cleanup share the original data
/// admission/connection; a retry keeps the same cutoff instead of aging it.
class HistoryRetentionChange {
  HistoryRetentionChange({
    required int days,
    required Future<void> Function(Future<void> Function()) access,
    required void Function() checkTarget,
    required Future<void> Function(int) saveDays,
    required Future<void> Function(int) clearBefore,
    DateTime Function()? now,
  }) : days = AppPreferences.historyRetentionDays.normalize(days),
       _access = access,
       _checkTarget = checkTarget,
       _saveDays = saveDays,
       _clearBefore = clearBefore,
       _now = now ?? DateTime.now;

  final int days;
  final Future<void> Function(Future<void> Function()) _access;
  final void Function() _checkTarget;
  final Future<void> Function(int) _saveDays, _clearBefore;
  final DateTime Function() _now;
  Future<void>? _pending;
  int? _cutoff;
  bool _complete = false;

  Future<void> run() {
    if (_complete) return Future.value();
    return _pending ??= Future<void>.sync(
      () => _access(() async {
        _checkTarget();
        await _saveDays(days);
        _checkTarget();
        if (days > 0) {
          _cutoff ??= _now()
              .subtract(Duration(days: days))
              .millisecondsSinceEpoch;
          await _clearBefore(_cutoff!);
        }
        _complete = true;
      }),
    ).whenComplete(() => _pending = null);
  }
}
