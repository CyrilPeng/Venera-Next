abstract class ListOrNull {
  static List<T>? from<T>(Iterable<dynamic>? i) {
    return i == null ? null : List.from(i);
  }
}
