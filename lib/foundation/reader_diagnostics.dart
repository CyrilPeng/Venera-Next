import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';

enum ReaderDiagnosticMode { paged, continuous, waterfall }

enum ReaderDiagnosticStage {
  localRead,
  sourceRead,
  processingWait,
  codecInitWait,
  firstDecodeWait,
  displayWait,
}

enum ReaderDiagnosticStop { timeout, review, background, interrupted, disposed }

/// An opt-in, in-memory capture. Its input API accepts no private text.
/// Durations are elapsed waits, not CPU time or proof of UI-thread blocking.
class ReaderDiagnostics extends ChangeNotifier {
  ReaderDiagnostics({
    int Function()? nowMicros,
    void Function(TimingsCallback)? attachTimings,
    void Function(TimingsCallback)? detachTimings,
    this.maxEvents = 480,
    this.maxFrames = 6000,
    this.maxImages = 256,
  }) : assert(maxEvents > 0 && maxFrames > 0 && maxImages > 0),
       _nowMicros = nowMicros ?? (() => Timeline.now),
       _attachTimings =
           attachTimings ??
           ((callback) =>
               SchedulerBinding.instance.addTimingsCallback(callback)),
       _detachTimings =
           detachTimings ??
           ((callback) =>
               SchedulerBinding.instance.removeTimingsCallback(callback));

  static const captureDuration = Duration(seconds: 45);
  static const maxReportCharacters = 60000;
  final int maxEvents, maxFrames, maxImages;
  final int Function() _nowMicros;
  final void Function(TimingsCallback) _attachTimings, _detachTimings;
  final _events = ListQueue<Map<String, Object>>();
  final _frames = ListQueue<List<int>>();
  final _imageIds = <int, int>{};
  Timer? _timer;
  int _generation = 0, _startedAt = 0, _duration = 0;
  int _droppedEvents = 0, _droppedFrames = 0, _ignoredImages = 0;
  int _inFlight = 0, _inFlightAtStop = 0;
  bool _recording = false, _hasCapture = false, _disposed = false;
  double _frameBudgetUs = 1000000 / 60;
  Map<String, Object> _configuration = {};
  Map<String, int> _cacheBefore = {}, _cacheAfter = {};
  ReaderDiagnosticStop? _stopReason;
  late final TimingsCallback _onFrames = _recordFrames;

  bool get isRecording => _recording;
  bool get hasCapture => _hasCapture;
  int get _elapsed => math.max(0, _nowMicros() - _startedAt);

  void _notifyChanged() {
    if (_disposed) return;
    // A delayed deadline can be detected while an image resolves during build.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      scheduleMicrotask(() {
        if (!_disposed) notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  bool _acceptSample() {
    if (_recording && _elapsed >= captureDuration.inMicroseconds) {
      stop(ReaderDiagnosticStop.timeout);
    }
    return _recording;
  }

  static Map<String, int> _cacheSnapshot() {
    final cache = PaintingBinding.instance.imageCache;
    return {
      'decodedBytes': cache.currentSizeBytes,
      'keepAliveImages': cache.currentSize,
      'liveImages': cache.liveImageCount,
      'pendingImages': cache.pendingImageCount,
    };
  }

  void start({
    required ReaderDiagnosticMode mode,
    required bool processingEnabled,
    required String appVersion,
    required double refreshRate,
  }) {
    if (_disposed) return;
    stop(ReaderDiagnosticStop.interrupted);
    clear(notify: false);
    final hz = refreshRate.isFinite && refreshRate >= 1 && refreshRate <= 1000
        ? refreshRate
        : 60.0;
    _frameBudgetUs = 1000000 / hz;
    _configuration = {
      'appVersion':
          appVersion.length <= 64 &&
              RegExp(
                r'^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?(?:\+\d+)?$',
              ).hasMatch(appVersion)
          ? appVersion
          : 'unknown',
      'platform': defaultTargetPlatform.name,
      'buildMode': kReleaseMode
          ? 'release'
          : kProfileMode
          ? 'profile'
          : 'debug',
      'readerMode': mode.name,
      'customProcessingEnabled': processingEnabled,
      'displayRefreshHz': hz,
    };
    _cacheBefore = _cacheSnapshot();
    _startedAt = _nowMicros();
    _recording = _hasCapture = true;
    _attachTimings(_onFrames);
    _timer = Timer(captureDuration, () => stop(ReaderDiagnosticStop.timeout));
    _notifyChanged();
  }

  void stop(ReaderDiagnosticStop reason) {
    if (!_recording) return;
    _duration = math.min(_elapsed, captureDuration.inMicroseconds);
    _recording = false;
    _timer?.cancel();
    _timer = null;
    _detachTimings(_onFrames);
    _cacheAfter = _cacheSnapshot();
    _inFlightAtStop = _inFlight;
    _imageIds.clear();
    _stopReason = reason;
    _notifyChanged();
  }

  void clear({bool notify = true}) {
    if (_recording) stop(ReaderDiagnosticStop.interrupted);
    _generation++;
    _hasCapture = false;
    _events.clear();
    _frames.clear();
    _imageIds.clear();
    _droppedEvents = _droppedFrames = _ignoredImages = _inFlight =
        _inFlightAtStop = 0;
    _duration = 0;
    _stopReason = null;
    _configuration = {};
    _cacheBefore = {};
    _cacheAfter = {};
    if (notify) _notifyChanged();
  }

  int? _imageId(int identity) {
    final existing = _imageIds[identity];
    if (existing != null) return existing;
    if (_imageIds.length >= maxImages) {
      _ignoredImages++;
      return null;
    }
    return _imageIds[identity] = _imageIds.length + 1;
  }

  ReaderDiagnosticSpan? beginImageSpan(
    int identity,
    ReaderDiagnosticStage stage,
  ) {
    if (!_acceptSample()) return null;
    final image = _imageId(identity);
    if (image == null) return null;
    _inFlight++;
    return ReaderDiagnosticSpan._(this, _generation, image, stage, _elapsed);
  }

  void recordCache(
    int identity, {
    required bool pending,
    required bool keepAlive,
    required bool live,
  }) {
    if (!_acceptSample()) return;
    final image = _imageId(identity);
    if (image == null) return;
    _append({
      'atUs': _elapsed,
      'image': image,
      'stage': 'cacheLookup',
      'pending': pending,
      'keepAlive': keepAlive,
      'live': live,
    });
  }

  void _append(Map<String, Object> event) {
    if (_events.length == maxEvents) {
      _events.removeFirst();
      _droppedEvents++;
    }
    _events.add(event);
  }

  void _recordFrames(List<FrameTiming> timings) {
    if (!_acceptSample()) return;
    for (final frame in timings) {
      if (_frames.length == maxFrames) {
        _frames.removeFirst();
        _droppedFrames++;
      }
      _frames.add([
        _elapsed,
        frame.buildDuration.inMicroseconds,
        frame.rasterDuration.inMicroseconds,
        frame.totalSpan.inMicroseconds,
      ]);
    }
  }

  Map<String, Object> _summary(Iterable<int> source) {
    final values = source.toList()..sort();
    if (values.isEmpty) return {'count': 0};
    return {
      'count': values.length,
      'medianUs': values[values.length ~/ 2],
      'p95Us': values[(values.length * .95).ceil() - 1],
      'maxUs': values.last,
    };
  }

  String exportJson() {
    final slow =
        _frames
            .where(
              (frame) => frame[1] > _frameBudgetUs || frame[2] > _frameBudgetUs,
            )
            .toList()
          ..sort(
            (a, b) => math.max(b[1], b[2]).compareTo(math.max(a[1], a[2])),
          );
    final events = _events.toList();
    final data = <String, Object?>{
      'schema': 1,
      'privacy':
          'No comic content, titles, paths, URLs, accounts, scripts, or error text.',
      'measurement':
          'Elapsed waits are not CPU time or UI-thread blocking. Source reads include encoded cache and source callbacks. Processing wait measures only custom image processing. Frame samples are not measured FPS.',
      'configuration': _configuration,
      'durationUs': _recording ? _elapsed : _duration,
      'stopReason': _stopReason?.name,
      'limits': {
        'seconds': captureDuration.inSeconds,
        'events': maxEvents,
        'frames': maxFrames,
        'images': maxImages,
        'reportCharacters': maxReportCharacters,
      },
      'droppedEvents': _droppedEvents,
      'droppedFrames': _droppedFrames,
      'ignoredImageLookups': _ignoredImages,
      'retainedEventCount': _events.length,
      'omittedEventsForCopy': 0,
      'inFlightStagesAtStop': _inFlightAtStop,
      'globalImageCacheBefore': _cacheBefore,
      'globalImageCacheAfter': _cacheAfter,
      'retainedFrameSamples': {
        'ui': _summary(_frames.map((frame) => frame[1])),
        'raster': _summary(_frames.map((frame) => frame[2])),
        'frameBudgetUs': _frameBudgetUs.round(),
        'overBudget': slow.length,
        'slowest': slow.take(40).toList(),
        'slowestColumns': ['receivedAtUs', 'uiUs', 'rasterUs', 'totalSpanUs'],
      },
      'retainedStageSamples': {
        for (final stage in ReaderDiagnosticStage.values)
          stage.name: _summary(
            _events
                .where((event) => event['stage'] == stage.name)
                .map((event) => event['waitUs'] as int),
          ),
      },
      'imageEvents': events,
    };
    var omitted = 0;
    while (true) {
      data['omittedEventsForCopy'] = omitted;
      final report = const JsonEncoder.withIndent('  ').convert(data);
      if (report.length <= maxReportCharacters || events.isEmpty) return report;
      // Keep copies within an issue comment; preserve the newest event details.
      final remove = math.max(
        1,
        ((report.length - maxReportCharacters) * events.length / report.length)
            .ceil(),
      );
      events.removeRange(0, remove);
      omitted += remove;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    stop(ReaderDiagnosticStop.disposed);
    clear(notify: false);
    super.dispose();
  }
}

class ReaderDiagnosticSpan {
  ReaderDiagnosticSpan._(
    this._owner,
    this._generation,
    this._image,
    this._stage,
    this._start,
  );
  final ReaderDiagnostics _owner;
  final int _generation, _image, _start;
  final ReaderDiagnosticStage _stage;
  bool _finished = false;

  void finish({bool success = true, int? bytes, int? width, int? height}) {
    if (_finished) return;
    _finished = true;
    if (_generation != _owner._generation || !_owner._acceptSample()) return;
    _owner._inFlight--;
    _owner._append({
      'atUs': _start,
      'image': _image,
      'stage': _stage.name,
      'waitUs': math.max(0, _owner._elapsed - _start),
      'success': success,
      if (bytes != null && bytes >= 0) 'bytes': bytes,
      if (width != null && width > 0) 'width': width,
      if (height != null && height > 0) 'height': height,
    });
  }
}
