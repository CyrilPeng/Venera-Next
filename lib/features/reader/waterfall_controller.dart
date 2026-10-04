import 'dart:async';

import 'package:dio/dio.dart';
import 'package:venera_next/network/request_scope.dart';

import 'package:venera_next/foundation/image_work.dart';
import 'waterfall_flow.dart';

/// Chapter loading policy; scrolling and frame callbacks belong to the view.
class WaterfallController {
  WaterfallController({
    required this.maxChapter,
    required this.load,
    required this.chapterId,
    required this.onChanged,
    required this.onPreviousError,
    ImageWork? imageWork,
  }) : _imageWork = imageWork ?? ImageWork();

  final int maxChapter;
  final Future<List<String>> Function(int chapter, RequestScope scope) load;
  final String Function(int chapter) chapterId;
  final void Function() onChanged;
  final void Function(Object, StackTrace) onPreviousError;
  final ImageWork _imageWork;
  final _pending = <ImageWorkTask>{};
  Future<void>? _disposal;
  final _flow = WaterfallChapterFlow();
  WaterfallFlowView get flow => _flow;
  RequestScope _scope = RequestScope();
  bool _disposed = false;
  bool _loadingAfter = false;
  bool _loadingBefore = false;
  bool _navigating = false;
  String? _afterError;
  int _revision = 0;

  bool get loadingAfter => _loadingAfter;
  String? get afterError => _afterError;
  int get revision => _revision;

  void initialize(WaterfallChapterSegment segment) {
    if (!_disposed && _flow.isEmpty) _flow.addAfter(segment);
  }

  bool _current(RequestScope scope) =>
      !_disposed && identical(scope, _scope) && !scope.isCancelled;

  Future<WaterfallChapterSegment> _load(int chapter, RequestScope scope) async {
    final request = RequestScope(parent: scope);
    final task = _imageWork.start(onCancel: request.cancel);
    if (task == null) {
      request.dispose();
      throw const RequestCancelled();
    }
    _pending.add(task);
    final completed = Completer<void>();
    var started = false;
    ({Object error, StackTrace stack})? failure;

    Future<List<String>> runOriginal() async {
      started = true;
      try {
        return await load(chapter, request);
      } catch (error, stack) {
        failure = (error: error, stack: stack);
        rethrow;
      } finally {
        completed.complete();
      }
    }

    Future<void> finish() async {
      // The UI may stop awaiting RequestScope.run before the accepted source
      // call returns. Keep its scope and session ownership until that return.
      if (started && !completed.isCompleted) await completed.future;
      final lateFailure = failure;
      if (lateFailure != null &&
          request.isCancelled &&
          lateFailure.error is! RequestCancelled &&
          !(lateFailure.error is DioException &&
              (lateFailure.error as DioException).type ==
                  DioExceptionType.cancel)) {
        task.recordFailure(lateFailure.error, lateFailure.stack);
      }
      request.dispose();
      _pending.remove(task);
      task.finish();
    }

    try {
      final images = await request.run(runOriginal);
      return WaterfallChapterSegment(
        chapter: chapter,
        eid: chapterId(chapter),
        images: List.unmodifiable(images),
      );
    } finally {
      unawaited(finish());
    }
  }

  void retryAfter() {
    if (_disposed) return;
    _afterError = null;
    onChanged();
  }

  Future<void> ensureAfter({
    required int current,
    required int threshold,
  }) async {
    if (_disposed || _navigating || _loadingAfter || _afterError != null) {
      return;
    }
    final scope = _scope;
    if (!_flow.shouldLoadAfter(
      current: current,
      threshold: threshold,
      maxChapter: maxChapter,
    )) {
      return;
    }
    _loadingAfter = true;
    onChanged();
    try {
      while (_current(scope) &&
          _flow.shouldLoadAfter(
            current: current,
            threshold: threshold,
            maxChapter: maxChapter,
          )) {
        final segment = await _load(_flow.lastChapter! + 1, scope);
        if (!_current(scope)) return;
        _flow.addAfter(segment);
        onChanged();
      }
    } on RequestCancelled {
      // Exit preparation is reversible; cancellation is not a retry error.
    } catch (error) {
      if (_current(scope)) _afterError = error.toString();
    } finally {
      if (_current(scope)) {
        _loadingAfter = false;
        onChanged();
      }
    }
  }

  /// Returns inserted image count so the view can restore its visible anchor.
  Future<int> ensureBefore({
    required int current,
    required int threshold,
  }) async {
    if (_disposed ||
        _navigating ||
        _loadingBefore ||
        !_flow.shouldLoadBefore(current: current, threshold: threshold)) {
      return 0;
    }
    final scope = _scope;
    _loadingBefore = true;
    try {
      final segment = await _load(_flow.firstChapter! - 1, scope);
      if (!_current(scope)) return 0;
      return _flow.addBefore(segment);
    } on RequestCancelled {
      return 0;
    } catch (error, stack) {
      if (_current(scope)) onPreviousError(error, stack);
      return 0;
    } finally {
      if (_current(scope)) _loadingBefore = false;
    }
  }

  /// A navigation supersedes prefetch and older navigation requests.
  Future<bool> navigate(int chapter) async {
    if (_disposed || chapter < 1 || chapter > maxChapter) return false;
    _revision++;
    _scope.cancel();
    _scope.dispose();
    final scope = _scope = RequestScope();
    _loadingAfter = false;
    _loadingBefore = false;
    _navigating = true;
    try {
      if (_flow.segmentOfChapter(chapter) != null) return true;
      final segment = await _load(chapter, scope);
      if (!_current(scope)) return false;
      _flow.reset(segment);
      _afterError = null;
      return true;
    } on RequestCancelled {
      return false;
    } catch (_) {
      if (!_current(scope)) return false;
      rethrow;
    } finally {
      if (_current(scope)) {
        _navigating = false;
        onChanged();
      }
    }
  }

  Future<void> dispose() {
    if (_disposal != null) return _disposal!;
    final completion = Completer<void>();
    _disposal = completion.future;
    _disposed = true;
    _revision++;
    _scope.cancel();
    _scope.dispose();
    completion.complete(
      Future.wait(_pending.map((task) => task.done).toList()).then((_) {}),
    );
    return completion.future;
  }
}
