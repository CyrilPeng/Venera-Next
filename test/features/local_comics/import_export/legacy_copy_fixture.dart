import 'dart:convert';

import 'package:venera_next/features/local_comics/import_export/comic_copy_record.dart';
import 'package:venera_next/foundation/file_system.dart';

/// The old writer had no source manifest. Keep that format in fixtures so the
/// current writer cannot accidentally make legacy compatibility tests pass.
ComicCopyRecord prepareLegacyComicCopy(
  Directory directory, {
  required String source,
  String? metadata,
}) {
  File(
    FilePath.join(directory.path, ComicCopyRecord.intentName),
  ).writeAsStringSync(
    jsonEncode({
      'version': 1,
      'id': '604ea347-0d40-40fd-a7e1-8514b94db862',
      'source': source,
      'metadata': metadata,
    }),
    flush: true,
  );
  return ComicCopyRecord.read(directory);
}
