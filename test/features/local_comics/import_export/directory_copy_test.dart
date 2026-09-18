import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/local_comics/import_export/import_export.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'package:venera_next/foundation/log.dart';

void main() {
  test(
    'a failed import restores existing directory and later comics still copy',
    () async {
      final root = Directory.systemTemp.createTempSync('comic-copy-');
      final muted = Log.isMuted;
      Log.isMuted = true;
      addTearDown(() {
        Log.isMuted = muted;
        root.deleteSync(recursive: true);
      });
      final bad = Directory('${root.path}/input/Bad/chapter')
        ..createSync(recursive: true);
      File('${bad.path}/page.jpg').createSync();
      final good = Directory('${root.path}/input/Good')..createSync();
      File('${good.path}/page.jpg').writeAsBytesSync([1, 2, 3]);
      final existing = Directory('${root.path}/output/Bad')
        ..createSync(recursive: true);
      File('${existing.path}/original.txt').writeAsStringSync('keep');
      final result = await ImportComic.debugCopyDirectories([
        bad.parent.path,
        good.path,
      ], existing.parent.path);
      expect(result.keys, [good.path]);
      expect(File('${existing.path}/original.txt').readAsStringSync(), 'keep');
      expect(Directory('${existing.path}/chapter').existsSync(), isFalse);
      expect(
        Directory('${existing.parent.path}/Bad_old').existsSync(),
        isFalse,
      );
      expect(File('${result[good.path]}/page.jpg').readAsBytesSync(), [
        1,
        2,
        3,
      ]);
    },
  );
}
