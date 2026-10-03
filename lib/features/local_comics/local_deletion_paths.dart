import 'dart:io';

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

/// Check both recorded paths and filesystem identities. The adapter resolves
/// existing ancestors too, so missing children under an alias stay protected.
/// Resolution errors propagate before any directory is handed to cleanup.
Future<List<String>> resolveLocalDirectoriesToDelete({
  required Iterable<String> candidates,
  required Iterable<String> retained,
  required String libraryPath,
  required Future<String> Function(String path) resolvePath,
}) async {
  final references = retained.toList();
  final selected = localDirectoriesToDelete(
    candidates: candidates,
    retained: references,
    libraryPath: libraryPath,
  );
  if (selected.isEmpty) return selected;
  final identities = <String, String>{};
  for (final path in {libraryPath, ...references, ...selected}) {
    identities[path] = await resolvePath(path);
  }
  final allowed = localDirectoriesToDelete(
    candidates: selected.map((path) => identities[path]!),
    retained: references.map((path) => identities[path]!),
    libraryPath: identities[libraryPath]!,
  ).toSet();
  // Keep original platform paths for I/O, including SAF paths. Do not delete
  // through a canonical target instead of the user's registered path.
  return selected.where((path) => allowed.contains(identities[path])).toList();
}

/// Native filesystem identity, including a missing suffix beneath an alias.
/// Broken links and inaccessible existing paths must not fall back to lexical
/// identity: their targets cannot be proven safe to delete.
Future<String> resolveLocalNativePath(String path) async {
  var ancestor = p.normalize(p.absolute(path));
  final suffix = <String>[];
  while (await FileSystemEntity.type(ancestor, followLinks: false) ==
      FileSystemEntityType.notFound) {
    final parent = p.dirname(ancestor);
    if (parent == ancestor) {
      throw FileSystemException('Cannot resolve deletion path', path);
    }
    suffix.add(p.basename(ancestor));
    ancestor = parent;
  }
  final resolved = await Directory(ancestor).resolveSymbolicLinks();
  return p.joinAll([resolved, ...suffix.reversed]);
}
