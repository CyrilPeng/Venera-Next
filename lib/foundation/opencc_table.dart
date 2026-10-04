/// Immutable, character-level conversion using the bundled two-column table.
/// Duplicate keys retain the last mapping, matching the existing table order.
class OpenCCTable {
  OpenCCTable._(Map<int, int> simplified, Map<int, int> traditional)
    : _simplified = Map.unmodifiable(simplified),
      _traditional = Map.unmodifiable(traditional);

  factory OpenCCTable.parse(String text) {
    final simplified = <int, int>{};
    final traditional = <int, int>{};
    for (final raw in text.split('\n')) {
      final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
      if (line.isEmpty || line.startsWith('#')) continue;
      final runes = line.runes.toList();
      if (runes.length != 2) continue;
      simplified[runes[0]] = runes[1];
      traditional[runes[1]] = runes[0];
    }
    return OpenCCTable._(simplified, traditional);
  }

  final Map<int, int> _simplified;
  final Map<int, int> _traditional;

  bool hasSimplified(String text) => text.runes.any(_simplified.containsKey);
  bool hasTraditional(String text) => text.runes.any(_traditional.containsKey);
  String toTraditional(String text) => _convert(text, _simplified);
  String toSimplified(String text) => _convert(text, _traditional);

  static String _convert(String text, Map<int, int> mapping) =>
      String.fromCharCodes(text.runes.map((rune) => mapping[rune] ?? rune));
}
