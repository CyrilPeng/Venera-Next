import 'dart:isolate';
import 'dart:io';
import 'sqlite_connection.dart';

class CacheScanResult {
  const CacheScanResult(this.totalSize, this.unmanagedFiles);
  final int totalSize;
  final List<String> unmanagedFiles;
}

typedef CacheScanner =
    Future<CacheScanResult> Function(String dbPath, String directory);

Future<CacheScanResult> scanCacheDirectory(String dbPath, String dir) async {
  return Isolate.run(() async {
    int totalSize = 0;
    List<String> unmanagedFiles = [];
    var db = openSqliteDatabase(dbPath);
    try {
      await for (var file in Directory(dir).list(recursive: true)) {
        if (file is File) {
          var size = await file.length();
          var segments = file.uri.pathSegments;
          var name = segments.last;
          var dir = segments.elementAtOrNull(segments.length - 2) ?? "*";
          var res = db.select(
            '''
              SELECT * FROM cache
              WHERE dir = ? AND name = ?
            ''',
            [dir, name],
          );
          if (res.isEmpty) {
            unmanagedFiles.add(file.path);
          } else {
            totalSize += size;
          }
        }
      }
    } finally {
      db.dispose();
    }
    return CacheScanResult(totalSize, unmanagedFiles);
  });
}
