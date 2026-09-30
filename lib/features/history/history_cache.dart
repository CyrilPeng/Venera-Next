import 'history_model.dart';

/// Read-through identity guard plus the ten most recently written records.
/// The repository determines which typed identities actually remain in storage.
class HistoryCache {
  HistoryCache({required this.identities, required this.load});
  final List<(String, int)> Function({String? id}) identities;
  final History? Function(String id, int type) load;
  Map<String, Set<int>>? _known;
  final _recent = <(String, int), History>{};

  void record(History item) {
    if (_known == null) {
      refresh();
    } else {
      // An id-only primary key can replace a record from another source.
      // Legacy tables may retain both: ask storage rather than assuming either.
      final current = identities(id: item.id).toSet();
      _known![item.id] = current.map((key) => key.$2).toSet();
      _recent.removeWhere(
        (key, _) => key.$1 == item.id && !current.contains(key),
      );
    }
    final key = (item.id, item.type.value);
    if (!_contains(key)) return;
    _recent[key] = item;
    if (_recent.length > 10) _recent.remove(_recent.keys.first);
  }

  History? find(String id, int type) {
    if (_known == null) refresh();
    final key = (id, type);
    if (!_contains(key)) return null;
    final cached = _recent[key];
    if (cached != null && cached.id == id && cached.type.value == type) {
      return cached;
    }
    _recent.remove(key);
    return load(id, type);
  }

  bool _contains((String, int) key) =>
      _known?[key.$1]?.contains(key.$2) ?? false;

  void refresh() {
    _known = {};
    for (final (id, type) in identities()) {
      (_known![id] ??= {}).add(type);
    }
    _recent.removeWhere((key, _) => !_contains(key));
  }

  void clear() {
    _known = null;
    _recent.clear();
  }
}
