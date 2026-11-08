enum KeywordMatchMode { contains, wholeWord, exactTag }

/// Options accompany the existing string lists, so reading old settings never
/// rewrites their order, whitespace, duplicates or case policy.
class KeywordRule {
  const KeywordRule(
    this.keyword, {
    this.mode = KeywordMatchMode.contains,
    this.caseSensitive = false,
  }) : isLegacy = false;

  const KeywordRule.legacy(this.keyword, {this.caseSensitive = true})
    : mode = KeywordMatchMode.contains,
      isLegacy = true;

  factory KeywordRule.suggested(String keyword, {bool tag = false}) =>
      KeywordRule(
        keyword,
        mode: tag
            ? KeywordMatchMode.exactTag
            : isShortAbbreviation(keyword)
            ? KeywordMatchMode.wholeWord
            : KeywordMatchMode.contains,
      );

  static final _shortAbbreviation = RegExp(r'^[a-zA-Z]{1,3}$');
  static bool isShortAbbreviation(String word) =>
      _shortAbbreviation.hasMatch(word.trim());

  factory KeywordRule.read(
    String keyword,
    String? options, {
    bool comments = false,
  }) {
    final parts = options?.split(':');
    if (parts != null && parts.length == 2 && keyword.trim().isNotEmpty) {
      final mode = switch (parts[0]) {
        'contains' => KeywordMatchMode.contains,
        'wholeWord' => KeywordMatchMode.wholeWord,
        'exactTag' when !comments => KeywordMatchMode.exactTag,
        _ => null,
      };
      final sensitive = switch (parts[1]) {
        'sensitive' => true,
        'insensitive' => false,
        _ => null,
      };
      if (mode != null && sensitive != null) {
        return KeywordRule(keyword, mode: mode, caseSensitive: sensitive);
      }
    }
    return KeywordRule.legacy(keyword, caseSensitive: !comments);
  }

  final String keyword;
  final KeywordMatchMode mode;
  final bool caseSensitive;
  final bool isLegacy;

  String? get storageOptions => isLegacy
      ? null
      : '${mode.name}:${caseSensitive ? 'sensitive' : 'insensitive'}';

  @override
  bool operator ==(Object other) =>
      other is KeywordRule &&
      keyword == other.keyword &&
      mode == other.mode &&
      caseSensitive == other.caseSensitive &&
      isLegacy == other.isLegacy;

  @override
  int get hashCode => Object.hash(keyword, mode, caseSensitive, isLegacy);
}

enum KeywordMatchField { title, subtitle, description, tag, comment }

/// Offsets refer to the original text, including case-insensitive matches.
class KeywordMatch {
  const KeywordMatch({
    required this.rule,
    required this.field,
    required this.text,
    required this.start,
    required this.end,
  });

  final KeywordRule rule;
  final KeywordMatchField field;
  final String text;
  final int start;
  final int end;
}
