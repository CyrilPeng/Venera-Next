abstract class ListOrNull {
  static List<T>? from<T>(Iterable<dynamic>? i) {
    return i == null ? null : List.from(i);
  }
}

abstract class MapOrNull {
  static Map<K, V>? from<K, V>(Map<dynamic, dynamic>? i) {
    return i == null ? null : Map<K, V>.from(i);
  }
}
