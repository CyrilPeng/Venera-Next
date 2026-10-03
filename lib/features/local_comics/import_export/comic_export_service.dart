import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/file_system.dart';
import '../local_comic_model.dart';

typedef ExportComicFunc =
    Future<File> Function(LocalComic comic, String outFilePath);

/// Owns staging files through the save operation; presentation supplies ports.
Future<void> exportLocalComics(
  List<LocalComic> comics, {
  required String cachePath,
  required String extension,
  required ExportComicFunc export,
  required Future<void> Function(String directory, String output) compress,
  required Future<void> Function(File file, String name) save,
  required bool Function() isCancelled,
  void Function(int current, int total)? onProgress,
  void Function()? onCompress,
}) async {
  if (comics.isEmpty || isCancelled()) return;
  final selected = List<LocalComic>.of(comics);
  final workspace = await Directory(cachePath).createTemp('comics-export-');
  try {
    final content = await Directory(
      FilePath.join(workspace.path, 'content'),
    ).create();
    final usedNames = <String>{};
    File? exported;
    for (var i = 0; i < selected.length; i++) {
      if (isCancelled()) return;
      final comic = selected[i];
      final base = sanitizeFileName(comic.title, maxLength: 100);
      var name = '$base$extension';
      var suffix = 2;
      while (!usedNames.add(name.toLowerCase())) {
        name = '$base (${suffix++})$extension';
      }
      final target = File(FilePath.join(content.path, name));
      await export(comic, target.path);
      exported = target;
      onProgress?.call(i + 1, selected.length);
      if (isCancelled()) return;
    }
    if (selected.length == 1) {
      await save(exported!, exported.name);
    } else {
      onCompress?.call();
      if (isCancelled()) return;
      final archive = File(FilePath.join(workspace.path, 'comics_export.zip'));
      await compress(content.path, archive.path);
      if (isCancelled()) return;
      await save(archive, 'comics_export.zip');
    }
  } finally {
    try {
      await workspace.delete(recursive: true);
    } catch (error, stack) {
      Log.error('Export cleanup', error, stack);
    }
  }
}
