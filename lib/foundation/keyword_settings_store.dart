import 'package:venera_next/foundation/reader_preference_settings.dart';
import 'application_preferences.dart';
import 'global_preference_store.dart';
import 'preferences.dart';

enum BlockedKeywordList {
  comics(KeywordPreferences.comics),
  comments(KeywordPreferences.comments);

  const BlockedKeywordList(this.preference);
  final StringListPreference preference;
  String get key => preference.key;
}

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
