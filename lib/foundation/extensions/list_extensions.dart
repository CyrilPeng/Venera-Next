extension ListExt<T> on List<T> {
  T? firstWhereOrNull(bool Function(T element) test) {
    for (var element in this) {
      if (test(element)) {
        return element;
      }
    }
    return null;
  }

  void addIfNotNull(T? value) {
    if (value != null) {
      add(value);
    }
  }

  /// Compare every element of this list with another list.
  /// Return true if all elements are equal.
  bool isEqualTo(List<T> list) {
    if (length != list.length) {
      return false;
    }
    for (int i = 0; i < length; i++) {
      if (this[i] != list[i]) {
        return false;
      }
    }
    return true;
  }
}
