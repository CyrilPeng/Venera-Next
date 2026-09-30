import 'package:venera_next/foundation/preferences.dart';
import 'appdata.dart';

enum ReaderPreferenceScope { active, global, device, comic }

/// Typed edits over the existing persistence format. Resolving an active scope
/// happens on each operation so toggling a scope cannot leave a stale binding.
class ReaderPreferenceStore {
  ReaderPreferenceStore({
    required this.settings,
    this.scope = ReaderPreferenceScope.active,
    this.comicId,
    this.sourceKey,
  }) {
    if ((comicId == null) != (sourceKey == null) ||
        (scope == ReaderPreferenceScope.comic && comicId == null)) {
      throw ArgumentError(
        'Comic settings require both comic ID and source key',
      );
    }
  }

  final Settings settings;
  final ReaderPreferenceScope scope;
  final String? comicId;
  final String? sourceKey;

  T read<T extends Object>(Preference<T> preference) {
    final Object? raw;
    if (scope == ReaderPreferenceScope.global) {
      raw = settings[preference.key];
    } else if (scope == ReaderPreferenceScope.comic ||
        (scope == ReaderPreferenceScope.active && comicId != null)) {
      raw = settings.getReaderSetting(comicId!, sourceKey!, preference.key);
    } else {
      raw = settings.getDeviceReaderSetting(preference.key);
    }
    return preference.normalize(raw);
  }

  void write<T extends Object>(Preference<T> preference, T value) {
    final normalized = preference.normalize(value);
    // Preserve the existing slider JSON representation for whole numbers.
    final stored = normalized is num && normalized.toInt() == normalized
        ? normalized.toInt()
        : normalized;
    switch (scope) {
      case ReaderPreferenceScope.global:
        settings[preference.key] = stored;
      case ReaderPreferenceScope.device:
        settings.setDeviceReaderSetting(preference.key, stored);
      case ReaderPreferenceScope.comic:
        settings.setReaderSetting(comicId!, sourceKey!, preference.key, stored);
      case ReaderPreferenceScope.active:
        settings.setActiveReaderSetting(
          comicId,
          sourceKey,
          preference.key,
          stored,
        );
    }
  }

  ReaderPreferenceBinding<T> bind<T extends Object>(Preference<T> preference) =>
      ReaderPreferenceBinding(this, preference);
}

class ReaderPreferenceBinding<T extends Object>
    implements PreferenceBinding<T> {
  const ReaderPreferenceBinding(this.store, this.preference);
  final ReaderPreferenceStore store;
  @override
  final Preference<T> preference;
  @override
  T read() => store.read(preference);
  @override
  void write(T value) => store.write(preference, value);
}
