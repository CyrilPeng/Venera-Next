import 'dart:async';

import 'package:dio/dio.dart' show CancelToken, DioException;
import 'package:venera_next/network/request_scope.dart';

import 'package:venera_next/foundation/image_work.dart';

/// Navigation capabilities shared by gallery and continuous view adapters.
abstract interface class ReaderNavigationViewport {
  void toPage(int page);
  Future<void> animateToPage(int page);
  bool toChapter(int chapter, {bool toLastPage = false});
}

class ReaderNavigationState {
  const ReaderNavigationState({
    required this.page,
    required this.chapter,
    required this.pendingPage,
    required this.jumpToLastPageOnLoad,
  });
  final int page;
  final int chapter;
  final int? pendingPage;
  final bool jumpToLastPageOnLoad;
  bool get isAnimating => pendingPage != null;
}

class ReaderContentState {
  const ReaderContentState({this.images, this.isLoading = false, this.error});
  final List<String>? images;
  final bool isLoading;
  final String? error;
}

/// Handle for one content load; only its owner may commit its result.
class ReaderContentLoad {
  ReaderContentLoad._();
  final scope = RequestScope();
  bool _started = false;
  bool _finished = false;
  bool _waitingForImageWork = false;

  /// This attempt was interrupted by image-work admission and may be replaced
  /// when that same owner resumes. Supersession alone does not request a retry.
  bool get waitingForImageWork => _waitingForImageWork;
}

enum ReaderContentLoadResult { ignored, ready, failed }

/// Owns navigation state and commands without widget, settings or storage access.
class ReaderController {
  ReaderController({
    required this.pageCount,
    required this.chapterCount,
    required this.animationEnabled,
    required this.viewport,
    required this.onChanged,
    required this.onPageChanged,
    required this.onError,
  });

  final int Function() pageCount;
  final int Function() chapterCount;
  final bool Function() animationEnabled;
  final ReaderNavigationViewport? Function() viewport;
  final void Function() onChanged;
  final void Function() onPageChanged;
  final void Function(Object, StackTrace) onError;

  ReaderContentState _content = const ReaderContentState();
  ReaderContentState get content => _content;
  ReaderContentLoad? _contentLoad;

  ReaderContentLoad beginContentLoad() {
    if (_disposed) throw StateError('ReaderController is disposed');
    _cancelContentLoad();
    final attempt = _contentLoad = ReaderContentLoad._();
    _content = ReaderContentState(images: _content.images, isLoading: true);
    return attempt;
  }

  bool _accepts(ReaderContentLoad attempt) =>
      !_disposed &&
      identical(_contentLoad, attempt) &&
      !attempt.scope.isCancelled &&
      !attempt._finished;

  bool startContentLoad(ReaderContentLoad attempt) {
    if (!_accepts(attempt) || attempt._started) return false;
    attempt._started = true;
    return true;
  }

  /// Runs one owned load through preparation, fetching and layout preparation.
  /// Superseded/disposed attempts cannot start a later phase or publish results.
  Future<ReaderContentLoadResult> loadContent(
    ReaderContentLoad attempt, {
    required Future<void> Function() beforeLoad,
    required Future<List<String>> Function(RequestScope) loadImages,
    required Future<void> Function() prepareMode,
    ImageWork? imageWork,
  }) async {
    if (!startContentLoad(attempt)) return ReaderContentLoadResult.ignored;
    final task = imageWork?.start(
      onCancel: () {
        attempt._waitingForImageWork = true;
        cancelContentLoad(attempt);
      },
    );
    if (imageWork != null && task == null) {
      attempt._waitingForImageWork = true;
      cancelContentLoad(attempt);
      return ReaderContentLoadResult.ignored;
    }
    try {
      await beforeLoad();
      if (!_accepts(attempt)) return ReaderContentLoadResult.ignored;
      final images = await loadImages(attempt.scope);
      if (!setContentImages(attempt, images)) {
        return ReaderContentLoadResult.ignored;
      }
      await prepareMode();
      return completeContentLoad(attempt)
          ? ReaderContentLoadResult.ready
          : ReaderContentLoadResult.ignored;
    } catch (error, stack) {
      final cancelled =
          error is RequestCancelled ||
          error is ImageWorkTaskCancelled ||
          (error is DioException && CancelToken.isCancel(error));
      if (!_accepts(attempt) && !cancelled) {
        task?.recordFailure(error, stack);
      }
      if (cancelled) {
        cancelContentLoad(attempt);
        return ReaderContentLoadResult.ignored;
      }
      return failContentLoad(attempt, error)
          ? ReaderContentLoadResult.failed
          : ReaderContentLoadResult.ignored;
    } finally {
      task?.finish();
    }
  }

  bool setContentImages(ReaderContentLoad attempt, List<String> images) {
    if (!_accepts(attempt)) return false;
    _content = ReaderContentState(
      images: List.unmodifiable(images),
      isLoading: true,
    );
    return true;
  }

  bool completeContentLoad(ReaderContentLoad attempt) {
    if (!_accepts(attempt)) return false;
    attempt._finished = true;
    attempt.scope.dispose();
    _content = ReaderContentState(images: _content.images);
    return true;
  }

  bool failContentLoad(ReaderContentLoad attempt, Object error) {
    if (!_accepts(attempt)) return false;
    attempt._finished = true;
    attempt.scope.dispose();
    _content = ReaderContentState(
      images: _content.images,
      error: error.toString(),
    );
    return true;
  }

  void cancelContentLoad(ReaderContentLoad attempt) {
    if (identical(_contentLoad, attempt)) _cancelContentLoad();
  }

  void _cancelContentLoad() {
    _contentLoad?.scope.cancel();
    _contentLoad?.scope.dispose();
    _contentLoad = null;
    if (_content.isLoading) {
      _content = ReaderContentState(
        images: _content.images,
        error: _content.error,
      );
    }
  }

  /// Activate an already loaded waterfall chapter without issuing a request.
  void replaceChapterImages(List<String> images) {
    if (_disposed) return;
    _cancelContentLoad();
    _content = ReaderContentState(images: List.unmodifiable(images));
  }

  int _page = 1;
  int _chapter = 1;
  int? _pendingPage;
  bool _jumpToLastPage = false;
  int _generation = 0;
  bool _disposed = false;

  ReaderNavigationState? _snapshot;

  ReaderNavigationState get state => _snapshot ??= ReaderNavigationState(
    page: _page,
    chapter: _chapter,
    pendingPage: _pendingPage,
    jumpToLastPageOnLoad: _jumpToLastPage,
  );

  /// Restore a mapped position before the view is ready to publish history.
  void restorePage(int page) {
    if (_disposed) return;
    _page = page;
    _snapshot = null;
  }

  void restoreChapter(int chapter) {
    if (_disposed) return;
    _chapter = chapter;
    _snapshot = null;
  }

  void setJumpToLastPage(bool value) {
    if (_disposed) return;
    _jumpToLastPage = value;
    _snapshot = null;
  }

  void setPage(int page) {
    if (_disposed) return;
    _page = page;
    _snapshot = null;
    onPageChanged();
  }

  /// Viewport callbacks from a superseded animation cannot change the target.
  void reportPage(int page) {
    if (_pendingPage != null && page != _pendingPage) return;
    setPage(page);
  }

  void resetAnimation() {
    _generation++;
    _pendingPage = null;
    _snapshot = null;
  }

  bool toPage(int page, {bool animated = true}) {
    if (_disposed) return false;
    final view = viewport();
    if (view == null || content.isLoading) return false;
    final count = pageCount();
    if (page < 1 || page > count) return false;
    if (page == _page && page != 1 && page != count && _pendingPage == null) {
      return false;
    }
    resetAnimation();
    if (animated && animationEnabled()) {
      _pendingPage = page;
      _snapshot = null;
      final generation = _generation;
      onChanged();
      if (_disposed || generation != _generation) return true;
      void finish() {
        if (_disposed || generation != _generation) return;
        _pendingPage = null;
        _snapshot = null;
        onChanged();
      }

      unawaited(
        Future<void>.sync(() => view.animateToPage(page)).then(
          (_) => finish(),
          onError: (Object error, StackTrace stack) {
            if (!_disposed) onError(error, stack);
            finish();
          },
        ),
      );
    } else {
      setPage(page);
      if (_disposed) return true;
      onChanged();
      if (!_disposed) view.toPage(page);
    }
    return true;
  }

  bool toChapter(int chapter, {bool toLastPage = false}) {
    if (_disposed ||
        content.isLoading ||
        chapter < 1 ||
        chapter > chapterCount()) {
      return false;
    }
    if (viewport()?.toChapter(chapter, toLastPage: toLastPage) ?? false) {
      return true;
    }
    _chapter = chapter;
    setPage(1);
    if (_disposed) return true;
    _jumpToLastPage = toLastPage;
    _snapshot = null;
    onChanged();
    return true;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelContentLoad();
    resetAnimation();
  }
}
