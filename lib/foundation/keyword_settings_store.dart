import 'package:venera_next/foundation/reader_preference_settings.dart';
import 'application_preferences.dart';
import 'global_preference_store.dart';
import 'keyword_rule.dart';
import 'preferences.dart';

enum BlockedKeywordList {
  comics(KeywordPreferences.comics, KeywordPreferences.comicRules),
  comments(KeywordPreferences.comments, KeywordPreferences.commentRules);

  const BlockedKeywordList(this.preference, this.ruleOptions);
  final StringListPreference preference;
  final StringMapPreference ruleOptions;
  String get key => preference.key;
}

enum KeywordRuleSaveResult { saved, duplicate, changed }

/// Keyword membership edits use the owner's existing persistence queue.
/// The current draft is read when the edit runs, so queued additions/deletions
/// merge with other edits and retries cannot act on an outdated row index.
class KeywordSettingsStore {
  const KeywordSettingsStore({
    required this.readSettings,
    required this.updateSettings,
  });

  final ReaderPreferenceSettings Function() readSettings;
  final Future<void> Function(void Function(ReaderPreferenceSettings) change)
  updateSettings;

  List<String> read(BlockedKeywordList target) =>
      GlobalPreferenceStore(readSettings()).read(target.preference).toList();

  bool contains(BlockedKeywordList target, String word) =>
      GlobalPreferenceStore(
        readSettings(),
      ).read(target.preference).contains(word);

  List<KeywordRule> rules(BlockedKeywordList target) =>
      _rules(GlobalPreferenceStore(readSettings()), target);

  KeywordRule? ruleFor(BlockedKeywordList target, String word) =>
      rules(target).where((rule) => rule.keyword == word).firstOrNull;

  List<KeywordRule> _rules(
    GlobalPreferenceStore preferences,
    BlockedKeywordList target,
  ) {
    final options = preferences.read(target.ruleOptions);
    return [
      for (final word in preferences.read(target.preference))
        KeywordRule.read(
          word,
          options[word],
          comments: target == BlockedKeywordList.comments,
        ),
    ];
  }

  /// Capture the edited rule, then compare against the admitted draft. A stale
  /// editor cannot overwrite a concurrent change or recreate a deleted rule.
  /// Recognizing the requested final value also makes persistence retries safe.
  Future<KeywordRuleSaveResult> saveRule(
    BlockedKeywordList target,
    KeywordRule rule, {
    KeywordRule? replacing,
  }) async {
    if (rule.keyword.trim().isEmpty ||
        (target == BlockedKeywordList.comments &&
            rule.mode == KeywordMatchMode.exactTag)) {
      throw ArgumentError('Invalid keyword rule');
    }
    var result = KeywordRuleSaveResult.saved;
    await updateSettings((draft) {
      final preferences = GlobalPreferenceStore(draft);
      final current = _rules(preferences, target);
      final previous = current
          .where((item) => item.keyword == replacing?.keyword)
          .firstOrNull;
      final existing = current
          .where((item) => item.keyword == rule.keyword)
          .firstOrNull;
      if (replacing != null && rule == replacing && previous == replacing) {
        return;
      }
      if (replacing != null && previous != replacing) {
        if (existing == rule &&
            (rule.keyword == replacing.keyword || previous == null)) {
          return;
        }
        result = KeywordRuleSaveResult.changed;
        return;
      }
      if (existing != null && rule.keyword != replacing?.keyword) {
        if (replacing == null && existing == rule) return;
        result = KeywordRuleSaveResult.duplicate;
        return;
      }
      final words = preferences.read(target.preference);
      preferences.write(target.preference, [
        for (final word in words)
          word == replacing?.keyword ? rule.keyword : word,
        if (replacing == null) rule.keyword,
      ]);
      final options = Map.of(preferences.read(target.ruleOptions));
      if (replacing != null) options.remove(replacing.keyword);
      final savedOptions = rule.storageOptions;
      if (savedOptions == null) {
        options.remove(rule.keyword);
      } else {
        options[rule.keyword] = savedOptions;
      }
      preferences.write(target.ruleOptions, options);
    });
    return result;
  }

  Future<bool> removeRule(
    BlockedKeywordList target,
    KeywordRule expected,
  ) async {
    var removed = true;
    await updateSettings((draft) {
      final preferences = GlobalPreferenceStore(draft);
      final current = _rules(
        preferences,
        target,
      ).where((rule) => rule.keyword == expected.keyword).firstOrNull;
      if (current == null) return;
      if (current != expected) {
        removed = false;
        return;
      }
      preferences.write(
        target.preference,
        preferences
            .read(target.preference)
            .where((word) => word != expected.keyword)
            .toList(),
      );
      final options = Map.of(preferences.read(target.ruleOptions))
        ..remove(expected.keyword);
      preferences.write(target.ruleOptions, options);
    });
    return removed;
  }

  /// Quick blocking adds captured rules atomically. Existing keywords keep
  /// their options, including changes made while admission or retry was pending.
  Future<void> blockRules(
    BlockedKeywordList target,
    Iterable<KeywordRule> selection,
  ) {
    final selected = List<KeywordRule>.unmodifiable(selection);
    if (selected.any(
      (rule) =>
          rule.keyword.trim().isEmpty ||
          (target == BlockedKeywordList.comments &&
              rule.mode == KeywordMatchMode.exactTag),
    )) {
      throw ArgumentError('Invalid keyword rules');
    }
    return updateSettings((draft) {
      final preferences = GlobalPreferenceStore(draft);
      final words = preferences.read(target.preference).toList();
      final options = Map.of(preferences.read(target.ruleOptions));
      var changed = false;
      for (final rule in selected) {
        if (words.contains(rule.keyword)) continue;
        words.add(rule.keyword);
        changed = true;
        final value = rule.storageOptions;
        if (value == null) {
          options.remove(rule.keyword);
        } else {
          options[rule.keyword] = value;
        }
      }
      if (!changed) return;
      preferences.write(target.preference, words);
      preferences.write(target.ruleOptions, options);
    });
  }

  Future<void> setBlocked(
    BlockedKeywordList target,
    String word,
    bool blocked,
  ) => updateSettings((draft) {
    final preferences = GlobalPreferenceStore(draft);
    final words = preferences.read(target.preference).toList();
    if (blocked) {
      if (!words.contains(word)) words.add(word);
    } else {
      words.removeWhere((candidate) => candidate == word);
      final options = Map.of(preferences.read(target.ruleOptions))
        ..remove(word);
      preferences.write(target.ruleOptions, options);
    }
    preferences.write(target.preference, words);
  });

  /// One idempotent membership assignment for the captured selection. Existing
  /// duplicates survive, but retries never append another copy of a selection.
  Future<void> blockAll(BlockedKeywordList target, Iterable<String> selection) {
    final selected = List<String>.of(selection);
    return updateSettings((draft) {
      final preferences = GlobalPreferenceStore(draft);
      final words = preferences.read(target.preference).toList();
      for (final word in selected) {
        if (!words.contains(word)) words.add(word);
      }
      preferences.write(target.preference, words);
    });
  }
}
