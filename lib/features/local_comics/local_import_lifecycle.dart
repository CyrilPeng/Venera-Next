import 'import_export/pdf_import_tasks.dart';
import 'local_storage_guard.dart';

/// PDF tasks cancel cooperatively; remaining accepted storage work drains.
Future<void Function()> prepareLocalImportsForExit() async {
  final releasePdf = await PdfImportTasks.instance.prepareForExit();
  try {
    final releaseStorage = await LocalComicStorageGuard.instance
        .prepareForExit();
    return () {
      releaseStorage();
      releasePdf();
    };
  } catch (_) {
    releasePdf();
    rethrow;
  }
}
