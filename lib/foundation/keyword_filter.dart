import 'application_preferences.dart';
import 'global_preference_store.dart';
import 'keyword_rule.dart';
import 'reader_preference_settings.dart';

export 'keyword_rule.dart';

/// Immutable matching snapshots shared by lists, comments and rule previews.
/// User text is always literal; no user-supplied regular expression is run.
class KeywordFilter {
  KeywordFilter(Iterable<String> words)
    : this.rules(words.map((word) => KeywordRule.legacy(word)));

  KeywordFilter.rules(Iterable<KeywordRule> rules)
    : rules = List.unmodifiable(rules);

  factory KeywordFilter.fromSettings(
    ReaderPreferenceSettings settings, {
    bool comments = false,
  }) {
    final preferences = GlobalPreferenceStore(settings);
    final words = preferences.read(
      comments ? KeywordPreferences.comments : KeywordPreferences.comics,
    );
    final options = preferences.read(
      comments
          ? KeywordPreferences.commentRules
          : KeywordPreferences.comicRules,
    );
    return KeywordFilter.rules([
      for (final word in words)
        KeywordRule.read(word, options[word], comments: comments),
    ]);
  }

  final List<KeywordRule> rules;
  late final List<String> words = List.unmodifiable(
    rules.map((rule) => rule.keyword),
  );
  late final _compiled = rules.map(_CompiledRule.new).toList(growable: false);

  bool blocksComment(String content) => commentMatch(content) != null;

  KeywordMatch? commentMatch(String content) {
    for (final rule in _compiled) {
      final match = rule.rule.isLegacy
          ? rule.legacyCommentMatch(content)
          : rule.textMatch(content, KeywordMatchField.comment);
      if (match != null) return match;
    }
    return null;
  }

  String? firstComicMatch({
    required String title,
    String? subtitle,
    required String description,
    Iterable<String> tags = const [],
  }) => comicMatch(
    title: title,
    subtitle: subtitle,
    description: description,
    tags: tags,
  )?.rule.keyword;

  KeywordMatch? comicMatch({
    required String title,
    String? subtitle,
    required String description,
    Iterable<String> tags = const [],
  }) {
    for (final rule in _compiled) {
      final match =
          rule.textMatch(title, KeywordMatchField.title) ??
          (subtitle == null
              ? null
              : rule.textMatch(subtitle, KeywordMatchField.subtitle)) ??
          rule.textMatch(description, KeywordMatchField.description);
      if (match != null) return match;
      for (final tag in tags) {
        final match = rule.tagMatch(tag);
        if (match != null) return match;
      }
    }
    return null;
  }
}

class _CompiledRule {
  _CompiledRule(this.rule);
  final KeywordRule rule;
  // Escaping keeps metacharacters literal and prevents pattern backtracking.
  late final _insensitive = RegExp(
    RegExp.escape(rule.keyword),
    caseSensitive: false,
    unicode: true,
  );
  static final _wordCharacter = RegExp(r'[\p{L}\p{N}\p{M}]', unicode: true);

  KeywordMatch? textMatch(String text, KeywordMatchField field) {
    if (rule.mode == KeywordMatchMode.exactTag) return null;
    if (rule.keyword.isEmpty && rule.mode == KeywordMatchMode.wholeWord) {
      return null;
    }
    var from = 0;
    while (from <= text.length) {
      final insensitive = rule.caseSensitive
          ? null
          : _insensitive.allMatches(text, from).firstOrNull;
      final start = rule.caseSensitive
          ? text.indexOf(rule.keyword, from)
          : insensitive?.start ?? -1;
      if (start < 0) return null;
      final end = rule.caseSensitive
          ? start + rule.keyword.length
          : insensitive!.end;
      if (rule.mode != KeywordMatchMode.wholeWord ||
          (!_hasWordCharacterBefore(text, start) &&
              !_hasWordCharacterAfter(text, end))) {
        return KeywordMatch(
          rule: rule,
          field: field,
          text: text,
          start: start,
          end: end,
        );
      }
      // Check overlapping occurrences too; a later occurrence may have a
      // boundary even when the first one was part of a larger word.
      from = start + 1;
    }
    return null;
  }

  KeywordMatch? tagMatch(String tag) {
    bool equal(String value) => rule.caseSensitive
        ? value == rule.keyword
        : value.toLowerCase() == rule.keyword.toLowerCase();
    if (equal(tag)) {
      return KeywordMatch(
        rule: rule,
        field: KeywordMatchField.tag,
        text: tag,
        start: 0,
        end: tag.length,
      );
    }
    final colon = tag.indexOf(':');
    if (colon < 0) return null;
    final nextColon = tag.indexOf(':', colon + 1);
    final end = nextColon < 0 ? tag.length : nextColon;
    if (!equal(tag.substring(colon + 1, end))) return null;
    return KeywordMatch(
      rule: rule,
      field: KeywordMatchField.tag,
      text: tag,
      start: colon + 1,
      end: end,
    );
  }

  KeywordMatch? legacyCommentMatch(String text) {
    // Preserve the old lowercase/substring semantics, including empty words.
    final folded = text.toLowerCase();
    final keyword = rule.keyword.toLowerCase();
    final start = folded.indexOf(keyword);
    if (start < 0) return null;
    var originalStart = start;
    var originalEnd = start + keyword.length;
    if (folded.length != text.length) {
      var offset = 0;
      var foldedOffset = 0;
      for (final rune in text.runes) {
        final value = String.fromCharCode(rune);
        final next = foldedOffset + value.toLowerCase().length;
        if (foldedOffset <= start && start < next) originalStart = offset;
        if (foldedOffset < start + keyword.length &&
            start + keyword.length <= next) {
          originalEnd = offset + value.length;
          break;
        }
        foldedOffset = next;
        offset += value.length;
      }
    }
    return KeywordMatch(
      rule: rule,
      field: KeywordMatchField.comment,
      text: text,
      start: originalStart,
      end: originalEnd,
    );
  }

  bool _hasWordCharacterBefore(String text, int offset) {
    if (offset == 0) return false;
    var start = offset - 1;
    if (start > 0 && _isLowSurrogate(text.codeUnitAt(start))) start--;
    return _wordCharacter.hasMatch(text.substring(start, offset));
  }

  bool _hasWordCharacterAfter(String text, int offset) {
    if (offset == text.length) return false;
    var end = offset + 1;
    if (end < text.length && _isHighSurrogate(text.codeUnitAt(offset))) end++;
    return _wordCharacter.hasMatch(text.substring(offset, end));
  }

  bool _isLowSurrogate(int value) => value >= 0xdc00 && value <= 0xdfff;
  bool _isHighSurrogate(int value) => value >= 0xd800 && value <= 0xdbff;
}
