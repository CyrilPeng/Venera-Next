import 'application_preferences.dart';
import 'global_preference_store.dart';
import 'keyword_rule.dart';
import 'reader_preference_settings.dart';

export 'keyword_rule.dart';

enum ComicKeywordScope { discovery, personal }

bool comicKeywordFilteringEnabled(
  ReaderPreferenceSettings settings,
  ComicKeywordScope scope,
) =>
    scope == ComicKeywordScope.discovery ||
    GlobalPreferenceStore(
      settings,
    ).read(KeywordPreferences.filterPersonalLists);

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
  late final _comicIndex = _ComicRuleIndex(rules);

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
    // Direct matching is cheaper for small snapshots. Large snapshots share
    // literal scans and tag lookups, especially when most rules do not match.
    if (rules.length < 16) {
      return _linearComicMatch(
        title: title,
        subtitle: subtitle,
        description: description,
        tags: tags,
      );
    }
    final firstText = _compiled.first.comicTextMatch(
      title,
      subtitle,
      description,
    );
    if (firstText != null) return firstText;
    final tag = _comicIndex.tagMatch(tags);
    if (tag?.index == 0) return tag!.match;
    if (!_comicIndex.mayMatchText(title, subtitle, description)) {
      return tag?.match;
    }
    // The combined patterns only reject nonmatches. The original matcher
    // still decides boundaries, offsets and field order for the winning rule.
    for (var i = 1; i < _compiled.length; i++) {
      final rule = _compiled[i];
      final match = rule.comicTextMatch(title, subtitle, description);
      if (match != null) return match;
      if (i == tag?.index) return tag!.match;
    }
    return null;
  }

  KeywordMatch? _linearComicMatch({
    required String title,
    required String? subtitle,
    required String description,
    required Iterable<String> tags,
  }) {
    for (final rule in _compiled) {
      final match = rule.comicTextMatch(title, subtitle, description);
      if (match != null) return match;
      for (final tag in tags) {
        final match = rule.tagMatch(tag);
        if (match != null) return match;
      }
    }
    return null;
  }
}

class _ComicRuleIndex {
  _ComicRuleIndex(this.rules) {
    final textWords = {true: <String>{}, false: <String>{}};
    for (var i = 0; i < rules.length; i++) {
      final rule = rules[i];
      final tags = rule.caseSensitive ? _sensitiveTags : _insensitiveTags;
      final keyword = rule.caseSensitive
          ? rule.keyword
          : rule.keyword.toLowerCase();
      // All modes retain exact tag matching, including legacy empty strings.
      tags.putIfAbsent(keyword, () => i);
      if (rule.mode != KeywordMatchMode.exactTag &&
          (rule.keyword.isNotEmpty || rule.mode == KeywordMatchMode.contains)) {
        textWords[rule.caseSensitive]!.add(rule.keyword);
      }
    }
    _textPatterns = [];
    for (final entry in textWords.entries) {
      final words = entry.value.toList(growable: false);
      // Large Unicode-folding alternations can become expensive in the VM.
      // Bound those groups while keeping sensitive literal scans shared.
      final batchSize = entry.key ? words.length : 32;
      for (var start = 0; start < words.length; start += batchSize) {
        final end = start + batchSize < words.length
            ? start + batchSize
            : words.length;
        _textPatterns.add(
          RegExp(
            '(?:${words.getRange(start, end).map(RegExp.escape).join('|')})',
            caseSensitive: entry.key,
            // Sensitive indexOf matches UTF-16 units; insensitive rules use
            // Unicode regex folding. Keep each original policy here too.
            unicode: !entry.key,
          ),
        );
      }
    }
  }

  final List<KeywordRule> rules;
  final _sensitiveTags = <String, int>{};
  final _insensitiveTags = <String, int>{};
  late final List<RegExp> _textPatterns;

  bool mayMatchText(String title, String? subtitle, String description) =>
      _textPatterns.any(
        (pattern) =>
            pattern.hasMatch(title) ||
            (subtitle != null && pattern.hasMatch(subtitle)) ||
            pattern.hasMatch(description),
      );

  int? _tagRule(String value) {
    final sensitive = _sensitiveTags[value];
    final insensitive = _insensitiveTags.isEmpty
        ? null
        : _insensitiveTags[value.toLowerCase()];
    if (sensitive == null) return insensitive;
    if (insensitive == null || sensitive < insensitive) return sensitive;
    return insensitive;
  }

  ({int index, KeywordMatch match})? tagMatch(Iterable<String> tags) {
    ({int index, KeywordMatch match})? best;
    for (final tag in tags) {
      final whole = _tagRule(tag);
      if (whole != null && (best == null || whole < best.index)) {
        best = (
          index: whole,
          match: KeywordMatch(
            rule: rules[whole],
            field: KeywordMatchField.tag,
            text: tag,
            start: 0,
            end: tag.length,
          ),
        );
      }
      final colon = tag.indexOf(':');
      if (colon >= 0) {
        final nextColon = tag.indexOf(':', colon + 1);
        final end = nextColon < 0 ? tag.length : nextColon;
        final part = _tagRule(tag.substring(colon + 1, end));
        if (part != null && (best == null || part < best.index)) {
          best = (
            index: part,
            match: KeywordMatch(
              rule: rules[part],
              field: KeywordMatchField.tag,
              text: tag,
              start: colon + 1,
              end: end,
            ),
          );
        }
      }
      if (best?.index == 0) return best;
    }
    return best;
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

  KeywordMatch? comicTextMatch(
    String title,
    String? subtitle,
    String description,
  ) =>
      textMatch(title, KeywordMatchField.title) ??
      (subtitle == null
          ? null
          : textMatch(subtitle, KeywordMatchField.subtitle)) ??
      textMatch(description, KeywordMatchField.description);

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
