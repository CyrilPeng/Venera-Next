import 'dart:typed_data';

import 'package:flutter_qjs/flutter_qjs.dart';

/// Owns references in one delivered configuration, including unused extension
/// fields. Callbacks borrow them; replacing a config transfers shared aliases
/// before retiring the previous one.
class ImageLoadingConfigOwner {
  ImageLoadingConfigOwner(Object? configuration)
    : _configuration = configuration,
      _references = _referencesIn(configuration);

  Object? _configuration;
  Set<JSRef> _references;
  final Set<JSRef> _released = Set.identity();
  bool _disposed = false;

  void replace(Object? configuration) {
    if (_disposed) throw StateError('Image configuration is closed');
    final next = _referencesIn(configuration);
    final previous = Set<JSRef>.identity()
      ..addAll(_references)
      ..addAll(_referencesIn(_configuration));
    _configuration = configuration;
    _references = next;
    _release(previous.where((reference) => !next.contains(reference)));
  }

  /// Discard an invalid or undelivered result without releasing references
  /// still borrowed by the current config (including callback self-aliases).
  void discard(Object? value, {Object? cause, StackTrace? stackTrace}) {
    final retained = Set<JSRef>.identity()
      ..addAll(_references)
      ..addAll(_referencesIn(_configuration));
    _release(
      _referencesIn(value).where((reference) => !retained.contains(reference)),
      cause: cause,
      stackTrace: stackTrace,
    );
  }

  /// Transfer the remaining references to the caller of a returned config.
  void detach() {
    _disposed = true;
    _configuration = null;
    _references.clear();
  }

  void dispose({Object? cause, StackTrace? stackTrace}) {
    if (_disposed) return;
    _disposed = true;
    final references = Set<JSRef>.identity()
      ..addAll(_references)
      ..addAll(_referencesIn(_configuration))
      ..addAll(_referencesIn(cause));
    _references.clear();
    _configuration = null;
    _release(references, cause: cause, stackTrace: stackTrace);
  }

  void _release(
    Iterable<JSRef> references, {
    Object? cause,
    StackTrace? stackTrace,
  }) {
    final failures = <({Object error, StackTrace stack})>[];
    for (final reference in references) {
      if (!_released.add(reference)) continue;
      try {
        reference.free();
      } catch (error, stack) {
        failures.add((error: error, stack: stack));
      }
    }
    if (failures.isEmpty) return;
    final cleanupFailure = ImageLoadingConfigCleanupFailure(failures);
    if (cause != null) {
      throw ImageLoadingConfigFailure(
        cause: cause,
        stackTrace: stackTrace ?? StackTrace.current,
        cleanupFailure: cleanupFailure,
      );
    }
    throw cleanupFailure;
  }
}

Set<JSRef> _referencesIn(Object? value) {
  final visited = Set<Object>.identity();
  final references = Set<JSRef>.identity();
  void visit(Object? value) {
    if (value == null || !visited.add(value)) return;
    if (value is JSRef) {
      references.add(value);
    } else if (value is Map) {
      for (final entry in value.entries.toList()) {
        visit(entry.key);
        visit(entry.value);
      }
    } else if (value is List && value is! TypedData && value is! List<int>) {
      for (final child in value.toList()) {
        visit(child);
      }
    }
  }

  visit(value);
  return references;
}

/// Release references in a configuration that was never handed to a download.
/// Aliases/cycles are visited once, and one failed release does not skip others.
void discardImageLoadingConfig(Object? configuration) {
  ImageLoadingConfigOwner(configuration).dispose();
}

class ImageLoadingConfigFailure implements Exception {
  const ImageLoadingConfigFailure({
    required this.cause,
    required this.stackTrace,
    required this.cleanupFailure,
  });

  final Object cause;
  final StackTrace stackTrace;
  final ImageLoadingConfigCleanupFailure cleanupFailure;

  @override
  String toString() => '$cause; $cleanupFailure';
}

class ImageLoadingConfigCleanupFailure implements Exception {
  ImageLoadingConfigCleanupFailure(
    Iterable<({Object error, StackTrace stack})> failures,
  ) : failures = List.unmodifiable(failures);

  final List<({Object error, StackTrace stack})> failures;

  @override
  String toString() =>
      'Image loading configuration cleanup failed: '
      '${failures.map((failure) => failure.error).join('; ')}';
}
