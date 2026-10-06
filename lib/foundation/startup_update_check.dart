import 'dart:async';

import 'package:venera_next/network/request_scope.dart';

/// A mounted application's startup chain. The source service independently
/// owns shared source checks; cancellation only retires this consumer's wait.
class StartupUpdateCheck {
  StartupUpdateCheck({
    required this.reserveCheck,
    required this.checkSources,
    required this.checkApplication,
    required this.applicationCheckEnabled,
  });

  final Future<bool> Function() reserveCheck;
  final Future<void> Function() checkSources;
  final Future<void> Function(RequestScope) checkApplication;
  final bool Function() applicationCheckEnabled;
  final _scope = RequestScope();
  Future<void>? _result;
  Future<void>? _settled;

  Future<void> start() {
    final result = _result;
    if (result != null) return result;
    final done = Completer<void>();
    _result = done.future;
    _settled = done.future
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(_scope.dispose);
    _run().then(done.complete, onError: done.completeError);
    return done.future;
  }

  Future<void> _run() async {
    try {
      _scope.check();
      // Already admitted persistence must actually finish before stores close.
      final reserved = await reserveCheck();
      _scope.check();
      if (!reserved) return;
      await _scope.run(checkSources);
      _scope.check();
      if (applicationCheckEnabled()) {
        await checkApplication(_scope);
      }
    } on RequestCancelled {
      // Closing this consumer is not a failed or successful update check.
    }
  }

  void cancel() => _scope.cancel();

  Future<void> closeAndWait() {
    cancel();
    return _settled ?? Future.value();
  }
}
