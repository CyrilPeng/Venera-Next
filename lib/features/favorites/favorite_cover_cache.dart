import 'dart:io';

import 'package:path/path.dart' as p;

/// Delete the legacy cover after its final favorite reference is committed.
void deleteFavoriteCover({
  required String dataDirectory,
  required String id,
  required int intKey,
}) {
  final fileName = (id + intKey.toString()).hashCode.toString();
  final file = File(p.join(dataDirectory, 'favorite_cover', fileName));
  if (file.existsSync()) {
    file.deleteSync();
  }
}
