import 'dart:async';

enum CloudflarePageState { notReady, challenging, ready }

/// A missing or loading document is not evidence that verification succeeded.
CloudflarePageState cloudflarePageState({
  required Object? readyState,
  required Object? head,
  required Object? body,
}) {
  if ((readyState != 'interactive' && readyState != 'complete') ||
      head is! String ||
      body is! String ||
      body.trim().isEmpty) {
    return CloudflarePageState.notReady;
  }
  if (head.contains('#challenge-success-text') ||
      head.contains('#challenge-error-text') ||
      head.contains('#challenge-form') ||
      body.contains('challenge-platform') ||
      body.contains('window._cf_chl_opt')) {
    return CloudflarePageState.challenging;
  }
  return CloudflarePageState.ready;
}

/// Coalesces WebView callbacks and owns finite readiness waits until dismissal.
class CloudflareVerification {
  CloudflareVerification({
    required this.readPage,
    required this.accept,
    required this.isCurrent,
    required this.onPassed,
    required this.onError,
    this.readinessAttempts = 4,
    this.readinessDelay = const Duration(milliseconds: 250),
  }) : assert(readinessAttempts > 0);

  final Future<CloudflarePageState> Function() readPage;
  final Future<bool> Function() accept;
  final bool Function() isCurrent;
  final void Function() onPassed;
  final void Function(Object, StackTrace) onError;
  final int readinessAttempts;
  final Duration readinessDelay;
  Future<void>? _checking;
  Timer? _timer;
  Completer<void>? _waiter;
  bool _requested = false;
  bool _disposed = false;
  bool _passed = false;

  bool get _canCheck => !_disposed && !_passed && isCurrent();

  Future<void> check() {
    if (!_canCheck) return Future.value();
    _requested = true;
    if (_checking case final checking?) return checking;
    final done = Completer<void>();
    _checking = done.future;
    unawaited(_run(done));
    return done.future;
  }

  Future<void> _run(Completer<void> done) async {
    try {
      do {
        _requested = false;
        for (var attempt = 0; attempt < readinessAttempts; attempt++) {
          if (!_canCheck) return;
          final state = await readPage();
          if (!_canCheck) return;
          if (state == CloudflarePageState.challenging) break;
          if (state == CloudflarePageState.ready) {
            final accepted = await accept();
            if (!_canCheck) return;
            if (accepted) {
              _passed = true;
              onPassed();
              return;
            }
          }
          if (attempt + 1 < readinessAttempts) await _waitForReadiness();
        }
      } while (_requested && _canCheck);
    } catch (error, stack) {
      onError(error, stack);
    } finally {
      _checking = null;
      done.complete();
    }
  }

  Future<void> _waitForReadiness() {
    final waiter = _waiter = Completer<void>();
    _timer = Timer(readinessDelay, () {
      _timer = null;
      _waiter = null;
      waiter.complete();
    });
    return waiter.future;
  }

  void dispose() {
    _disposed = true;
    _requested = false;
    _timer?.cancel();
    _timer = null;
    _waiter?.complete();
    _waiter = null;
  }
}
