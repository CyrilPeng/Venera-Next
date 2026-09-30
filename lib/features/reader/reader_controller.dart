import 'dart:async';

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

/// Owns navigation state and commands without widget, settings or storage access.
class ReaderController {
  ReaderController({
    required this.pageCount,
    required this.chapterCount,
    required this.isLoading,
    required this.animationEnabled,
    required this.viewport,
    required this.onChanged,
    required this.onPageChanged,
    required this.onError,
  });

  final int Function() pageCount;
  final int Function() chapterCount;
  final bool Function() isLoading;
  final bool Function() animationEnabled;
  final ReaderNavigationViewport? Function() viewport;
  final void Function() onChanged;
  final void Function() onPageChanged;
  final void Function(Object, StackTrace) onError;

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
    if (view == null || isLoading()) return false;
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
    if (_disposed || isLoading() || chapter < 1 || chapter > chapterCount()) {
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
    resetAnimation();
  }
}
