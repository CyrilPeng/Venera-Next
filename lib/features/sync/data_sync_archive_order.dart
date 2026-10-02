/// Natural order for archive names: numeric day/version fields compare by value.
/// Non-numeric runs retain ordinal ordering so legacy names stay readable.
/// Equal numeric spellings use the original name as a deterministic tie-breaker.
int compareDataSyncArchiveNames(String first, String second) {
  final firstParts = _parts
      .allMatches(first)
      .map((match) => match[0]!)
      .toList();
  final secondParts = _parts
      .allMatches(second)
      .map((match) => match[0]!)
      .toList();
  for (var i = 0; i < firstParts.length && i < secondParts.length; i++) {
    final a = firstParts[i];
    final b = secondParts[i];
    final numeric = _isDigit(a.codeUnitAt(0)) && _isDigit(b.codeUnitAt(0));
    final comparison = numeric ? _compareDigits(a, b) : a.compareTo(b);
    if (comparison != 0) return comparison;
  }
  final count = firstParts.length.compareTo(secondParts.length);
  return count != 0 ? count : first.compareTo(second);
}

final _parts = RegExp(r'[0-9]+|[^0-9]+');
final _leadingZeroes = RegExp(r'^0+');
bool _isDigit(int character) => character >= 48 && character <= 57;

int _compareDigits(String first, String second) {
  final a = first.replaceFirst(_leadingZeroes, '');
  final b = second.replaceFirst(_leadingZeroes, '');
  // Compare lengths before digits, avoiding integer overflow on remote input.
  final length = a.length.compareTo(b.length);
  return length != 0 ? length : a.compareTo(b);
}
