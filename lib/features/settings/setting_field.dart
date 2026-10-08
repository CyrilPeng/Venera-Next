import 'dart:convert';

import 'package:venera_next/foundation/preferences.dart';
import 'package:venera_next/foundation/reader_preference_settings.dart';
import 'package:venera_next/foundation/reader_preference_store.dart';

/// An immutable field target, independent of the form that presents it.
/// A missing preference retains the legacy nullable, heterogeneous value.
class SettingField<T> {
  const SettingField({
    required this.key,
    this.preference,
    this.comicId,
    this.sourceKey,
    this.scope = ReaderPreferenceScope.global,
  });

  const SettingField.reader({
    required this.key,
    this.preference,
    this.comicId,
    this.sourceKey,
    bool useDeviceSettings = false,
  }) : scope = comicId != null
           ? ReaderPreferenceScope.comic
           : useDeviceSettings
           ? ReaderPreferenceScope.device
           : ReaderPreferenceScope.global;

  final String key;
  final Preference<T>? preference;
  final String? comicId, sourceKey;
  final ReaderPreferenceScope scope;

  bool matches(SettingField<T> other) =>
      key == other.key &&
      comicId == other.comicId &&
      sourceKey == other.sourceKey &&
      scope == other.scope &&
      identical(preference, other.preference);
}

/// Edits join the owner's admitted persistence queue immediately. Mutable
/// inputs are captured before admission; inheritance and active-scope writes
/// are resolved against the draft supplied when that queue runs the edit.
class SettingFieldStore {
  const SettingFieldStore({
    required this.readSettings,
    required this.updateSettings,
  });

  final ReaderPreferenceSettings Function() readSettings;
  final Future<void> Function(void Function(ReaderPreferenceSettings) change)
  updateSettings;

  ReaderPreferenceStore _store(
    SettingField<Object?> field,
    ReaderPreferenceSettings settings,
  ) => ReaderPreferenceStore(
    settings: settings,
    comicId: field.comicId,
    sourceKey: field.sourceKey,
    scope: field.scope,
  );

  T? read<T>(SettingField<T> field) {
    final raw = _store(field, readSettings()).readRaw(field.key);
    final preference = field.preference;
    return preference == null ? raw as T? : preference.normalize(raw);
  }

  Future<void> save<T>(SettingField<T> field, T value) {
    final preference = field.preference;
    final snapshot = jsonEncode(
      preference == null ? value : preference.normalize(value),
    );
    return updateSettings((settings) {
      final decoded = jsonDecode(snapshot);
      final typed = field.preference;
      final store = _store(field, settings);
      if (typed != null) {
        store.write(typed, typed.normalize(decoded));
        return;
      }
      store.writeRaw(field.key, decoded);
    });
  }
}
