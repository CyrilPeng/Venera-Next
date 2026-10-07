/// A viewport may only report chapter edges for the content that created it.
class ReaderChapterNavigationRequest {
  const ReaderChapterNavigationRequest({
    required this.identity,
    required this.isCurrent,
    required this.canPrevious,
    required this.canNext,
    required this.reversed,
    required this.select,
  });
  final Object identity;
  final bool Function() isCurrent;
  final bool canPrevious, canNext, reversed;
  final void Function(int direction) select;
}

class ReaderChapterNavigationAction {
  ReaderChapterNavigationAction._(this._owner, this._request, this.direction);
  final ReaderChapterNavigationController _owner;
  final ReaderChapterNavigationRequest _request;
  final int direction;
  bool get reversed => _request.reversed;
  bool get isCurrent => identical(_owner.action, this);
  void select() => _owner._select(this);
}

/// Owns the visible edge and rejects retired signals and captured actions.
class ReaderChapterNavigationController {
  ReaderChapterNavigationController({required this.onChanged});
  final void Function() onChanged;
  ReaderChapterNavigationAction? _action;
  int _generation = 0;
  bool _disposed = false;
  ReaderChapterNavigationAction? get action =>
      !_disposed && _action?._request.isCurrent() == true ? _action : null;

  void report(ReaderChapterNavigationRequest? request, int direction) {
    if (_disposed || request == null || !request.isCurrent()) return;
    if (direction != -1 && direction != 0 && direction != 1) return;
    if (direction == -1 && !request.canPrevious ||
        direction == 1 && !request.canNext) {
      return;
    }
    final previous = action;
    if (direction == 0) {
      if (previous != null && previous._request.identity != request.identity) {
        return;
      }
      if (_action == null) return;
      _action = null;
    } else {
      if (previous != null &&
          previous._request.identity == request.identity &&
          previous.direction == direction) {
        return;
      }
      _action = ReaderChapterNavigationAction._(this, request, direction);
    }
    _generation++;
    onChanged();
  }

  void _select(ReaderChapterNavigationAction action) {
    if (!identical(this.action, action)) return;
    _action = null;
    final generation = ++_generation;
    onChanged();
    if (_disposed ||
        generation != _generation ||
        !action._request.isCurrent()) {
      return;
    }
    action._request.select(action.direction);
  }

  void dispose() {
    _disposed = true;
    _generation++;
    _action = null;
  }
}
