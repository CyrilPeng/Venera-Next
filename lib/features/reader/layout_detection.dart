import 'dart:async';
import 'dart:ui' as ui;

import 'package:venera_next/foundation/comic_layout.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'package:venera_next/network/image_http_client.dart';
import 'package:venera_next/network/image_loading_config.dart';
import 'package:venera_next/network/images.dart';

class ComicLayoutProbeFailure implements Exception {
  ComicLayoutProbeFailure(
    Iterable<({String stage, Object error, StackTrace stack})> failures,
  ) : failures = List.unmodifiable(failures);

  final List<({String stage, Object error, StackTrace stack})> failures;

  @override
  String toString() =>
      'Layout probe failed: ${failures.map((failure) => '${failure.stage}: ${failure.error}').join('; ')}';
}

/// Samples encoded dimensions with a bounded UI wait and a separate lifetime.
/// Downloads use the shared reader cache, but cancellation releases only this
/// probe's subscriptions. [done] also joins work still pending after timeout.
class ComicLayoutProbe {
  ComicLayoutProbe({
    Stream<ImageDownloadProgress> Function(String, String?, String, String)?
    loader,
    Future<ui.ImmutableBuffer> Function(Uint8List)? createBuffer,
    Future<ui.ImageDescriptor> Function(ui.ImmutableBuffer)? createDescriptor,
  }) : _loader = loader ?? ImageDownloader.loadComicImage,
       _createBuffer = createBuffer ?? ui.ImmutableBuffer.fromUint8List,
       _createDescriptor = createDescriptor ?? ui.ImageDescriptor.encoded {
    // A caller may first await the UI result. Keep a late cleanup failure
    // available through done without an unhandled duplicate error meanwhile.
    _done.future.ignore();
  }

  final Stream<ImageDownloadProgress> Function(String, String?, String, String)
  _loader;
  final Future<ui.ImmutableBuffer> Function(Uint8List) _createBuffer;
  final Future<ui.ImageDescriptor> Function(ui.ImmutableBuffer)
  _createDescriptor;
  final _readers = <_ProbeDownload>{};
  final _failures = <({String stage, Object error, StackTrace stack})>[];
  final _result = Completer<ComicLayoutDetection>();
  final _done = Completer<void>();
  final _cancellation = Completer<void>();
  Timer? _timeout;
  bool _started = false;
  bool _cancelled = false;

  Future<void> get done => _done.future;
  bool get isCancelled => _cancelled;

  /// Stop admission immediately. Completion is acknowledged by [done], not by
  /// the prompt unknown result returned to the UI.
  void cancel() {
    if (_cancelled || _done.isCompleted) return;
    _cancelled = true;
    _cancellation.complete();
    _timeout?.cancel();
    if (!_result.isCompleted) {
      _result.complete(const ComicLayoutDetection(ComicLayout.unknown, 0));
    }
    for (final reader in _readers.toList()) {
      // Each sample's finally awaits this exact first cancellation Future.
      unawaited(reader.cancel());
    }
    if (!_started) _done.complete();
  }

  /// A probe is single-use; repeated calls share the same result and lifetime.
  Future<ComicLayoutDetection> detect({
    required List<String> images,
    required String? sourceKey,
    required String comicId,
    required String chapterId,
  }) {
    if (!_started && !_cancelled) {
      _started = true;
      unawaited(_run(images, sourceKey, comicId, chapterId));
    }
    return _result.future;
  }

  Future<void> _run(
    List<String> images,
    String? sourceKey,
    String comicId,
    String chapterId,
  ) async {
    var ratios = <double?>[];
    try {
      // Covers alone are not representative. Keep the six-sample consensus
      // while limiting both native work and reads to two concurrent samples.
      final sample = images
          .skip(1)
          .take(ComicLayoutDetection.maxSamples)
          .toList();
      if (sample.length >= ComicLayoutDetection.minSamples) {
        ratios = List<double?>.filled(sample.length, null);
        var next = 0;
        Future<void> readSamples() async {
          while (!_cancelled && next < sample.length) {
            final index = next++;
            ratios[index] = await _readRatio(
              sample[index],
              sourceKey,
              comicId,
              chapterId,
            );
          }
        }

        _timeout = Timer(const Duration(seconds: 8), cancel);
        await Future.wait([readSamples(), readSamples()]);
      }
    } catch (error, stack) {
      _record('sampling', error, stack);
    } finally {
      _timeout?.cancel();
      _timeout = null;
      if (_failures.isEmpty) {
        _done.complete();
        if (!_result.isCompleted) {
          _result.complete(
            ComicLayoutDetection.fromRatios(ratios.whereType<double>()),
          );
        }
      } else {
        final failure = ComicLayoutProbeFailure(_failures);
        final stack = _failures.first.stack;
        _done.completeError(failure, stack);
        if (!_result.isCompleted) _result.completeError(failure, stack);
      }
    }
  }

  void _check() {
    if (_cancelled) throw const _ProbeCancelled();
  }

  void _record(String stage, Object error, StackTrace stack) {
    _failures.add((stage: stage, error: error, stack: stack));
  }

  Future<double?> _readRatio(
    String image,
    String? sourceKey,
    String comicId,
    String chapterId,
  ) async {
    if (_cancelled) return null;
    _ProbeDownload? reader;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    var stage = 'read';
    try {
      Uint8List? bytes;
      if (image.startsWith('file://')) {
        // Reader keys are raw paths: preserve literal # and % sequences.
        bytes = await readFileBytesChecked(
          File(image.substring(7)),
          requireNonEmpty: true,
          checkStop: _check,
          cancelSignal: _cancellation.future,
          canRetry: () => !_cancelled,
        );
      } else {
        reader = _ProbeDownload((error, stack) {
          if (_cancelled || _isCleanupFailure(error)) {
            _record('read', error, stack);
          }
        });
        _readers.add(reader);
        final stream = _loader(image, sourceKey, comicId, chapterId);
        _check();
        bytes = await reader.read(stream);
      }
      _check();
      if (bytes == null || bytes.isEmpty) return null;
      stage = 'buffer creation';
      buffer = await _createBuffer(bytes);
      _check();
      stage = 'descriptor creation';
      descriptor = await _createDescriptor(buffer);
      _check();
      stage = 'dimensions';
      if (descriptor.width <= 0 || descriptor.height <= 0) return null;
      return descriptor.height / descriptor.width;
    } catch (error, stack) {
      // Offline/corrupt samples may be skipped. A real failure arriving after
      // cancellation belongs to the owner whose UI can no longer report it.
      if (error is! _ProbeCancelled &&
          (_cancelled || _isCleanupFailure(error))) {
        _record(stage, error, stack);
      }
      return null;
    } finally {
      try {
        descriptor?.dispose();
      } catch (error, stack) {
        _record('descriptor disposal', error, stack);
      }
      try {
        buffer?.dispose();
      } catch (error, stack) {
        _record('buffer disposal', error, stack);
      }
      if (reader != null) {
        try {
          await reader.cancel();
        } catch (error, stack) {
          _record('subscription cancellation', error, stack);
        } finally {
          _readers.remove(reader);
        }
      }
    }
  }
}

class _ProbeCancelled implements Exception {
  const _ProbeCancelled();
}

bool _isCleanupFailure(Object error) =>
    error is ImageHttpCleanupFailure ||
    error is ImageLoadingConfigCleanupFailure ||
    error is ImageLoadingConfigFailure;

/// Owns the subscription's first cancel Future, including reentrant cancellation
/// during listen. Unlike StreamIterator, repeated cancel calls keep that Future.
class _ProbeDownload {
  _ProbeDownload(this._onLateError);

  final void Function(Object error, StackTrace stack) _onLateError;
  final _bytes = Completer<Uint8List?>();
  StreamSubscription<ImageDownloadProgress>? _subscription;
  Completer<void>? _cancelled;
  bool _listening = false;
  bool _cancelling = false;

  Future<Uint8List?> read(Stream<ImageDownloadProgress> stream) {
    if (_cancelled != null) return _bytes.future;
    _listening = true;
    try {
      _subscription = stream.listen(
        (event) {
          if (!_bytes.isCompleted && event.imageBytes != null) {
            _bytes.complete(event.imageBytes);
          }
        },
        onError: (Object error, StackTrace stack) {
          if (!_bytes.isCompleted) {
            _bytes.completeError(error, stack);
          } else {
            _onLateError(error, stack);
          }
        },
        onDone: () {
          if (!_bytes.isCompleted) _bytes.complete(null);
        },
        cancelOnError: false,
      );
    } catch (error, stack) {
      if (!_bytes.isCompleted) {
        _bytes.completeError(error, stack);
      } else {
        _onLateError(error, stack);
      }
    } finally {
      _listening = false;
      if (_cancelled != null) _cancelSubscription();
    }
    return _bytes.future;
  }

  Future<void> cancel() {
    if (_cancelled != null) return _cancelled!.future;
    _cancelled = Completer<void>();
    _cancelled!.future.ignore();
    if (!_bytes.isCompleted) _bytes.complete(null);
    if (!_listening) _cancelSubscription();
    return _cancelled!.future;
  }

  void _cancelSubscription() {
    if (_cancelling) return;
    _cancelling = true;
    _cancelled!.complete(Future<void>.sync(() => _subscription?.cancel()));
  }
}
