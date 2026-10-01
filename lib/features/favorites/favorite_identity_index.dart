/// Reference counts keyed by the complete persisted comic identity.
/// Local commits override an in-flight snapshot; older snapshots are ignored.
class FavoriteIdentityIndex {
  final _counts = <(String, int), int>{};
  final _overrides = <(String, int), int>{};
  var _generation = 0;
  bool _refreshing = false;

  int get length => _counts.length;
  bool contains(String id, int type) => _counts.containsKey((id, type));

  int beginRefresh() {
    _refreshing = true;
    _overrides.clear();
    return ++_generation;
  }

  void setCount((String, int) identity, int count) {
    _set(identity, count);
    if (_refreshing) _overrides[identity] = count;
  }

  void _set((String, int) identity, int count) {
    if (count > 0) {
      _counts[identity] = count;
    } else {
      _counts.remove(identity);
    }
  }

  bool completeRefresh(int generation, Map<(String, int), int> snapshot) {
    if (!_refreshing || generation != _generation) return false;
    _counts.clear();
    for (final entry in snapshot.entries) {
      _set(entry.key, entry.value);
    }
    for (final entry in _overrides.entries) {
      _set(entry.key, entry.value);
    }
    _overrides.clear();
    _refreshing = false;
    return true;
  }

  void failRefresh(int generation) {
    if (generation != _generation) return;
    _overrides.clear();
    _refreshing = false;
  }

  void clear() {
    _generation++;
    _refreshing = false;
    _overrides.clear();
    _counts.clear();
  }
}
