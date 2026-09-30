import 'appdata.dart';
import 'preferences.dart';
import 'application_configuration.dart';

/// Typed global settings access, preserving unknown keys and existing writes.
class GlobalPreferenceStore {
  const GlobalPreferenceStore(this.settings);
  final Settings settings;

  NetworkConfiguration get network =>
      NetworkConfiguration.read((key) => settings[key]);
  AppearanceConfiguration get appearance =>
      AppearanceConfiguration.read((key) => settings[key]);

  T read<T extends Object>(Preference<T> preference) =>
      preference.normalize(settings[preference.key]);

  void write<T extends Object>(Preference<T> preference, T value) {
    final normalized = preference.normalize(value);
    settings[preference.key] = normalized is Map
        ? Map.of(normalized)
        : normalized is num && normalized.toInt() == normalized
        ? normalized.toInt()
        : normalized;
  }

  PreferenceBinding<T> bind<T extends Object>(Preference<T> preference) =>
      _GlobalPreferenceBinding(this, preference);
}

class _GlobalPreferenceBinding<T extends Object>
    implements PreferenceBinding<T> {
  const _GlobalPreferenceBinding(this.store, this.preference);
  final GlobalPreferenceStore store;
  @override
  final Preference<T> preference;
  @override
  T read() => store.read(preference);
  @override
  void write(T value) => store.write(preference, value);
}
