import 'package:venera_next/network/request_scope.dart';

import 'waterfall_flow.dart';

/// Chapter loading policy; scrolling and frame callbacks belong to the view.
class WaterfallController {
  WaterfallController({
    required this.maxChapter,
    required this.load,
    required this.chapterId,
    required this.onChanged,
    required this.onPreviousError,
  });

  final int maxChapter;
  final Future<List<String>> Function(int chapter, RequestScope scope) load;
  final String Function(int chapter) chapterId;
  final void Function() onChanged;
  final void Function(Object, StackTrace) onPreviousError;
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
    try {
      final images = await request.run(() => load(chapter, request));
      return WaterfallChapterSegment(
        chapter: chapter,
        eid: chapterId(chapter),
        images: List.unmodifiable(images),
      );
    } finally {
      request.dispose();
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

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _revision++;
    _scope.cancel();
    _scope.dispose();
  }
}
