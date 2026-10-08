/// Typed storage keys shared by settings forms and immutable configuration snapshots.
sealed class Preference<T> {
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

/// Legacy navigation indices are stored as strings. Integer JSON values and
/// parseable numeric strings remain readable; only indices in range are valid.
final class StringIndexPreference extends Preference<String> {
  const StringIndexPreference(
    super.key,
    super.defaultValue, {
    required this.length,
  }) : assert(length > 0);
  final int length;
  @override
  String normalize(Object? value) {
    final index = value is int
        ? value
        : value is String
        ? int.tryParse(value)
        : null;
    return index != null && index >= 0 && index < length
        ? '$index'
        : defaultValue;
  }
}

final class NullableStringPreference extends Preference<String?> {
  const NullableStringPreference(String key) : super(key, null);
  @override
  String? normalize(Object? value) => value is String ? value : null;
}

/// Reading produces an immutable view without rewriting the stored list.
/// Unknown string identifiers, order, duplicates and empty markers survive.
final class StringListPreference extends Preference<List<String>> {
  const StringListPreference(String key) : super(key, const []);
  @override
  Object get storageDefault => <String>[];
  @override
  List<String> normalize(Object? value) => List<String>.unmodifiable(
    value is List ? value.whereType<String>() : const <String>[],
  );
}

/// Null means not configured; an empty list is an explicit empty selection.
final class NullableStringListPreference extends Preference<List<String>?> {
  const NullableStringListPreference(String key) : super(key, null);
  @override
  List<String>? normalize(Object? value) => value is List
      ? List<String>.unmodifiable(value.whereType<String>())
      : null;
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
    this.aliases = const {},
  });
  final List<String> choices;
  final bool legacyNullDefault;
  final Map<String, String> aliases;
  @override
  Object? get storageDefault => legacyNullDefault ? null : defaultValue;
  @override
  String normalize(Object? value) {
    if (value is! String) return defaultValue;
    final canonical = aliases[value] ?? value;
    return choices.contains(canonical) ? canonical : defaultValue;
  }
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

/// A rounded item count with zero reserved for automatic layout. The zero
/// check precedes clamping so small fractions retain the legacy auto sentinel.
final class AutoCountPreference extends Preference<int> {
  const AutoCountPreference(String key, {required this.min, required this.max})
    : assert(min > 0 && max >= min),
      super(key, 0);
  final int min, max;
  @override
  int normalize(Object? value) {
    if (value is! num || !value.isFinite) return defaultValue;
    final count = value.round();
    return count == 0 ? 0 : count.clamp(min, max);
  }
}

/// Round supported integers without shortening an out-of-range value by
/// clamping it. Invalid values use the explicitly chosen safe default.
final class RoundedIntPreference extends Preference<int> {
  const RoundedIntPreference(
    super.key,
    super.defaultValue, {
    required this.min,
    required this.max,
  });
  final int min, max;
  @override
  int normalize(Object? value) {
    if (value is! num || !value.isFinite) return defaultValue;
    final rounded = value.round();
    return rounded >= min && rounded <= max ? rounded : defaultValue;
  }
}
