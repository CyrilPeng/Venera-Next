import 'package:path/path.dart' as p;

/// Keep directories still referenced by another record, including overlapping
/// roots. Comparisons are lexical; callers retain the original platform paths.
List<String> localDirectoriesToDelete({
  required Iterable<String> candidates,
  required Iterable<String> retained,
  required String libraryPath,
}) {
  String normalize(String path) => p.normalize(p.absolute(path));
  final library = normalize(libraryPath);
  final protected = retained.map(normalize).toList();
  final selected = <String>[];
  final seen = <String>[];
  for (final candidate in candidates) {
    final path = normalize(candidate);
    if (p.equals(path, library) || p.isWithin(path, library)) continue;
    if (protected.any(
      (other) =>
          p.equals(path, other) ||
          p.isWithin(path, other) ||
          p.isWithin(other, path),
    )) {
      continue;
    }
    if (seen.any((other) => p.equals(path, other))) continue;
    seen.add(path);
    selected.add(candidate);
  }
  return selected;
}
