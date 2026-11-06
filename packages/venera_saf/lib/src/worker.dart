// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 VeneraNext contributors

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'native_backend.dart';
import 'overrides.dart';

/// Each isolate has an idempotently initialized worker. Errors are returned
/// with their stack instead of being replaced by null. Disposal rejects new
/// work, drains running operations and releases unacknowledged descriptors.
class SAFTaskWorker {
  factory SAFTaskWorker() => _instance;
  SAFTaskWorker._();
  static final _instance = SAFTaskWorker._();

  Future<void>? _initializing;
  Future<void>? _disposing;
  Isolate? _isolate;
  SendPort? _commands;
  ReceivePort? _events;
  Completer<void>? _exited;
  final _pending = <int, Completer<dynamic>>{};
  final _transfers = <int, NativeSafDescriptor>{};
  var _sequence = 0;

  Future<void> init() async {
    if (_disposing != null) await _disposing;
    await (_initializing ??= _start());
  }

  Future<void> _start() async {
    final ready = Completer<void>();
    ready.future.ignore();
    final events = ReceivePort();
    _events = events;
    final exited = Completer<void>();
    _exited = exited;
    events.listen((dynamic message) {
      if (message == null) {
        final error = StateError(
          'SAF worker exited before completing its tasks',
        );
        if (!ready.isCompleted) ready.completeError(error);
        for (final pending in _pending.values) {
          pending.completeError(error);
        }
        _pending.clear();
        for (final lease in _transfers.values) {
          lease.dispose();
        }
        _transfers.clear();
        _commands = null;
        _isolate = null;
        _initializing = null;
        events.close();
        _events = null;
        if (!exited.isCompleted) exited.complete();
        return;
      }
      if (message is! List) return;
      if (message.length == 2 && message[0] == 'ready') {
        _commands = message[1] as SendPort;
        ready.complete();
        return;
      }
      if (message.length == 2 && message[0] is String) {
        final error = RemoteError(message[0] as String, message[1].toString());
        if (!ready.isCompleted) ready.completeError(error);
        for (final pending in _pending.values) {
          pending.completeError(error);
        }
        _pending.clear();
        for (final lease in _transfers.values) {
          lease.dispose();
        }
        _transfers.clear();
        return;
      }
      if (message.length < 3) return;
      final id = message[1] as int;
      if (message[0] == 'descriptor') {
        final pending = _pending[id];
        try {
          if (pending != null) {
            _transfers[id] = NativeSafDescriptor.retain(message[2] as int);
          }
        } catch (error, stack) {
          _pending.remove(id);
          pending?.completeError(error, stack);
        } finally {
          _commands?.send(['ack', id]);
        }
        return;
      }
      final pending = _pending.remove(id);
      if (message[0] == 'adopted') {
        final lease = _transfers.remove(id);
        if (pending != null && lease != null) {
          pending.complete(lease);
        } else {
          lease?.dispose();
          pending?.completeError(
            StateError('Provider descriptor adoption failed'),
          );
        }
      } else if (pending != null) {
        if (message[0] == 'result') {
          pending.complete(message[2]);
        } else if (message[0] == 'error') {
          pending.completeError(
            message[2],
            StackTrace.fromString(message[3] as String),
          );
        }
      }
    });
    try {
      _isolate = await Isolate.spawn(
        _workerEntry,
        events.sendPort,
        onExit: events.sendPort,
        onError: events.sendPort,
        errorsAreFatal: true,
      );
      await ready.future;
    } catch (_) {
      _isolate?.kill(priority: Isolate.immediate);
      _events?.close();
      _events = null;
      _isolate = null;
      _commands = null;
      if (!exited.isCompleted) exited.complete();
      _initializing = null;
      rethrow;
    }
  }

  Future<T> runTask<T>(Function function, List<dynamic> args) async {
    if (_disposing != null) throw StateError('SAF worker is closing');
    await init();
    if (_disposing != null || _commands == null) {
      throw StateError('SAF worker is closing');
    }
    final id = ++_sequence;
    final completion = Completer<dynamic>();
    _pending[id] = completion;
    try {
      _commands!.send(['task', id, function, args]);
    } catch (_) {
      _pending.remove(id);
      rethrow;
    }
    return (await completion.future) as T;
  }

  Future<void> dispose() => _disposing ??= _close().whenComplete(() {
    _disposing = null;
  });

  Future<void> _close() async {
    final initializing = _initializing;
    if (initializing == null) return;
    await initializing;
    // Adopt every descriptor and finish every outstanding operation before
    // telling the worker to exit. Closing must not return while provider IO
    // remains in flight or while a sender still owns a descriptor lease.
    await Future.wait(
      _pending.values
          .map(
            (pending) => pending.future.then<void>(
              (_) {},
              onError: (Object _, StackTrace _) {},
            ),
          )
          .toList(),
    );
    _commands?.send(['close']);
    await _exited?.future;
  }
}

void _workerEntry(SendPort events) => IOOverrides.runWithIOOverrides(() {
  final commands = ReceivePort();
  final tasks = <int, Future<void>>{};
  final leases = <int, NativeSafDescriptor>{};
  var closing = false;
  events.send(['ready', commands.sendPort]);
  commands.listen((dynamic message) async {
    if (message is! List) return;
    if (message[0] == 'ack') {
      final id = message[1] as int;
      leases.remove(id)?.dispose();
      events.send(['adopted', id, null]);
      return;
    }
    if (message[0] == 'close') {
      closing = true;
      await Future.wait(tasks.values.toList());
      for (final lease in leases.values) {
        lease.dispose();
      }
      leases.clear();
      commands.close();
      Isolate.exit();
    }
    if (message[0] != 'task' || closing) return;
    final id = message[1] as int;
    tasks[id] = () async {
      try {
        final result = await Function.apply(
          message[2] as Function,
          message[3] as List,
        );
        if (result is NativeSafDescriptor) {
          if (closing) {
            result.dispose();
          } else {
            leases[id] = result;
            events.send(['descriptor', id, result.token]);
          }
        } else {
          events.send(['result', id, result]);
        }
      } catch (error, stack) {
        try {
          events.send(['error', id, error, stack.toString()]);
        } catch (_) {
          events.send([
            'error',
            id,
            RemoteError(error.toString(), stack.toString()),
            stack.toString(),
          ]);
        }
      } finally {
        tasks.remove(id);
      }
    }();
  });
}, SafIOOverrides());
