import 'dart:async';
import 'dart:collection';

class Channel<T> {
  final Queue<T> _queue;

  final Queue<_PendingPush<T>> _pendingPushes = Queue<_PendingPush<T>>();

  final int size;

  Channel(this.size) : _queue = Queue<T>();

  Completer? _pushCompleter;

  var currentSize = 0;

  var isClosed = false;

  Future<void> push(T item) async {
    if (isClosed) {
      return;
    }
    if (currentSize >= size) {
      final pendingPush = _PendingPush(item);
      _pendingPushes.addLast(pendingPush);
      return pendingPush.completer.future;
    }
    _addItem(item);
  }

  Future<T?> pop() async {
    while (_queue.isEmpty) {
      if (isClosed) {
        return null;
      }
      _pushCompleter ??= Completer();
      await _pushCompleter!.future;
    }
    var item = _queue.removeFirst();
    currentSize--;
    _drainPendingPushes();
    return item;
  }

  void close() {
    isClosed = true;
    _pushCompleter?.complete();
    for (var pendingPush in _pendingPushes) {
      pendingPush.completer.complete();
    }
    _pendingPushes.clear();
  }

  void _addItem(T item) {
    if (isClosed) {
      return;
    }
    _queue.addLast(item);
    currentSize++;
    _pushCompleter?.complete();
    _pushCompleter = null;
  }

  void _drainPendingPushes() {
    while (!isClosed && currentSize < size && _pendingPushes.isNotEmpty) {
      var pendingPush = _pendingPushes.removeFirst();
      _addItem(pendingPush.item);
      pendingPush.completer.complete();
    }
  }
}

class _PendingPush<T> {
  _PendingPush(this.item);

  final T item;

  final Completer<void> completer = Completer<void>();
}
