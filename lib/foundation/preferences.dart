/// Typed storage keys shared by settings forms and immutable configuration snapshots.
sealed class Preference<T extends Object> {
  const Preference(this.key, this.defaultValue);
  final String key;
  final T defaultValue;
  Object? get storageDefault => defaultValue;
  T normalize(Object? value);
}

final class StringPreference extends Preference<String> {
  const StringPreference(super.key, super.defaultValue);
  @override
  String normalize(Object? value) => value is String ? value : defaultValue;
}

final class StringMapPreference extends Preference<Map<String, String>> {
  const StringMapPreference(String key) : super(key, const {});
  @override
  Object get storageDefault => <String, String>{};
  @override
  Map<String, String> normalize(Object? value) => Map.unmodifiable({
    if (value is Map)
      for (final entry in value.entries)
        if (entry.key is String && entry.value is String)
          entry.key as String: entry.value as String,
  });
}

abstract interface class PreferenceBinding<T extends Object> {
  Preference<T> get preference;
  T read();
  void write(T value);
}

final class BoolPreference extends Preference<bool> {
  const BoolPreference(super.key, super.defaultValue);
  @override
  bool normalize(Object? value) => value is bool ? value : defaultValue;
}

final class ChoicePreference extends Preference<String> {
  const ChoicePreference(
    super.key,
    super.defaultValue,
    this.choices, {
    this.legacyNullDefault = false,
  });
  final List<String> choices;
  final bool legacyNullDefault;
  @override
  Object? get storageDefault => legacyNullDefault ? null : defaultValue;
  @override
  String normalize(Object? value) =>
      value is String && choices.contains(value) ? value : defaultValue;
}

final class NumericPreference extends Preference<num> {
  const NumericPreference(
    super.key,
    super.defaultValue, {
    required this.min,
    required this.max,
    required this.step,
    this.integer = false,
  });
  final double min;
  final double max;
  final double step;
  final bool integer;
  @override
  num normalize(Object? value) {
    final number = value is num && value.isFinite ? value : defaultValue;
    final bounded = number.toDouble().clamp(min, max);
    return integer ? bounded.toInt() : bounded;
  }
}
