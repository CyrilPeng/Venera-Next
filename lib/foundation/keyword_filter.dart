/// Matching rules shared by comic lists and ordinary/chapter comments.
/// Callers supply the current typed keywords; matching does not edit settings.
class KeywordFilter {
  KeywordFilter(Iterable<String> words) : words = List.unmodifiable(words);
  final List<String> words;

  bool blocksComment(String content) {
    final lower = content.toLowerCase();
    return words.any((word) => lower.contains(word.toLowerCase()));
  }

  /// Comics are case-sensitive. Tags match exactly, including either the full
  /// namespaced tag or the segment immediately after its first colon.
  String? firstComicMatch({
    required String title,
    String? subtitle,
    required String description,
    Iterable<String> tags = const [],
  }) {
    for (final word in words) {
      if (title.contains(word) ||
          (subtitle?.contains(word) ?? false) ||
          description.contains(word)) {
        return word;
      }
      for (final tag in tags) {
        if (tag == word || (tag.contains(':') && tag.split(':')[1] == word)) {
          return word;
        }
      }
    }
    return null;
  }
}
