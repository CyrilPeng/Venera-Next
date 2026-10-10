import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import '../local_storage_guard.dart';
import 'cbz.dart';
import 'comic_import_service.dart';
import 'epub_import.dart';
import 'pdf_import.dart';
import 'pdf_import_batch.dart';
import 'import_presentation.dart';
import 'pdf_import_tasks.dart';

class ImportComic {
  final ComicImportService service;
  final String? selectedFolder;
  final bool copyToLocal;

  final ImportComicPresentation presentation;

  const ImportComic({
    this.selectedFolder,
    this.copyToLocal = true,
    this.presentation = const ImportComicPresentation(),
    this.service = const ComicImportService(
      localManager: LocalManager.new,
      favoritesManager: LocalFavoritesManager.new,
    ),
  });

  Future<bool> cbz(SelectionOperation operation) async {
    final file = await operation.pickFile(
      () => selectFile(
        ext: ['cbz', 'zip', '7z', 'cb7'],
        checkStop: operation.checkActive,
      ),
    );
    if (file == null) return false;
    final controller = presentation.showLoading(allowCancel: false);
    try {
      await operation.useFile(
        file,
        (source) => CBZ.import(
          source,
          registerComic: (comic) =>
              service.registerComic(comic, folder: selectedFolder),
        ),
      );
      presentation.showMessage(
        message: 'Imported @a comics'.tlParams({'a': 1}),
      );
      return true;
    } finally {
      controller?.close();
    }
  }

  Future<bool> multipleCbz(SelectionOperation operation) async {
    final selection = await operation.pickDirectory(
      () => DirectoryPicker().pickDirectory(
        directAccess: true,
        checkStop: operation.checkActive,
      ),
    );
    if (selection == null) return false;
    return operation.useDirectory(selection, _multipleCbz);
  }

  Future<bool> _multipleCbz(Directory dir) async {
    final controller = presentation.showLoading(allowCancel: false);
    try {
      return await _showImportResult(
        () => service.archives(dir, folder: selectedFolder),
      );
    } finally {
      controller?.close();
    }
  }

  Future<bool> pdf(SelectionOperation operation) async {
    final selected = await operation.pickFiles(
      () => selectFiles(
        ext: ['pdf'],
        uniformTypeIdentifiers: ['com.adobe.pdf'],
        checkStop: operation.checkActive,
      ),
    );
    if (selected.isEmpty) return false;
    final task = operation.transferFiles(
      selected,
      () => PdfImportTasks.instance.add(
        files: selected,
        batch: PdfImportBatch(
          containsTitle: (title) => LocalManager().findByName(title) != null,
          importFile: (file, title, onProgress, cancellation) async {
            await PdfComicImporter.import(
              file,
              title: title,
              onProgress: onProgress,
              cancellation: cancellation,
              registerComic: (comic) =>
                  service.registerComic(comic, folder: selectedFolder),
            );
          },
        ),
      ),
    );
    await presentation.showPdfTask(task);
    // Closing the view accepts the task. Its eventual completion must not
    // navigate away from whatever the user is reading in the meantime.
    return true;
  }

  Future<bool> epub(SelectionOperation operation) async {
    final selected = await operation.pickFile(
      () => selectFile(ext: ['epub'], checkStop: operation.checkActive),
    );
    if (selected == null) return false;
    final controller = presentation.showLoading(
      allowCancel: false,
      withProgress: true,
      message: 'Importing EPUB'.tl,
    );
    try {
      await operation.useFile(
        selected,
        (file) => EpubComicImporter.import(
          file,
          registerComic: (comic) =>
              service.registerComic(comic, folder: selectedFolder),
          onProgress: (current, total) {
            controller
              ?..setProgress(current / total)
              ..setMessage(
                'Importing EPUB (@a/@b)'.tlParams({'a': current, 'b': total}),
              );
          },
        ),
      );
    } finally {
      controller?.close();
    }
    presentation.showMessage(message: 'Imported @a comics'.tlParams({'a': 1}));
    return true;
  }

  Future<bool> ehViewer(SelectionOperation operation) async {
    final dbFile = await operation.pickFile(
      () => selectFile(ext: ['db'], checkStop: operation.checkActive),
    );
    if (dbFile == null) return false;
    final directory = await operation.pickDirectory(
      () => DirectoryPicker().pickDirectory(checkStop: operation.checkActive),
    );
    if (directory == null) return false;
    return _showImportResult(
      () => service.runImport((importing) async {
        if (!copyToLocal) await directory.retainAccessForSession();
        operation.checkActive();
        return operation.useDirectory(
          directory,
          (comicSource) => operation.useFile(dbFile, (file) async {
            var cancelled = false;
            final controller = presentation.showLoading(
              onCancel: () => cancelled = true,
            );
            try {
              return await importing.ehViewer(
                file,
                comicSource,
                defaultFolder: '(EhViewer)Default'.tl,
                copy: copyToLocal,
                isCancelled: () => cancelled,
                onScanComplete: controller?.close,
              );
            } finally {
              controller?.close();
            }
          }),
        );
      }),
    );
  }

  Future<bool> directory(bool single, SelectionOperation operation) async {
    final selection = await operation.pickDirectory(
      () => DirectoryPicker().pickDirectory(checkStop: operation.checkActive),
    );
    if (selection == null) return false;
    return _showImportResult(
      () => service.runImport((importing) async {
        if (!copyToLocal) await selection.retainAccessForSession();
        operation.checkActive();
        return operation.useDirectory(
          selection,
          (directory) => importing.directory(
            directory,
            single: single,
            copy: copyToLocal,
            folder: selectedFolder,
          ),
        );
      }),
    );
  }

  Future<bool> localDownloads() => _showImportResult(() async {
    final scanned = await service.runRecovery((importing) async {
      var cancelled = false;
      final controller = presentation.showLoading(
        onCancel: () => cancelled = true,
      );
      try {
        return await importing.localDownloads(
          isCancelled: () => cancelled,
          onScanComplete: controller?.close,
        );
      } finally {
        controller?.close();
      }
    });
    if (scanned.pendingCopies.isEmpty) return scanned;
    var count = scanned.importedCount;
    var succeeded = scanned.succeeded;
    final issues = [...scanned.issues];
    final remaining = [...scanned.pendingCopies];
    for (final pending in scanned.pendingCopies) {
      final favorites = await service.runRecovery(
        (operation) async => operation.copyRecoveryFolders(),
      );
      final choice = await presentation.chooseCopyRecovery(
        title: pending.title,
        previousFolder: pending.folder,
        folders: favorites.folders,
      );
      if (choice == null) continue;
      final loading = presentation.showLoading(allowCancel: false);
      late ComicImportResult recovered;
      try {
        recovered = await service.runRecovery(
          (operation) => operation.recoverCopy(
            pending.directory,
            folder: choice.folder,
            intentDigest: pending.intentDigest,
            favorites: favorites,
          ),
        );
      } finally {
        loading?.close();
      }
      count += recovered.importedCount;
      succeeded = succeeded && recovered.succeeded;
      issues.addAll(recovered.issues);
      if (recovered.succeeded) remaining.remove(pending);
    }
    return ComicImportResult(
      succeeded: succeeded,
      importedCount: count,
      issues: issues,
      pendingCopies: remaining,
    );
  });

  Future<bool> _showImportResult(
    Future<ComicImportResult> Function() action,
  ) async {
    try {
      final result = await action();
      for (final issue in result.issues) {
        final message = switch (issue.kind) {
          ComicImportIssueKind.invalidComic => 'Invalid Comic'.tl,
          ComicImportIssueKind.localPathNotFound => 'Local path not found'.tl,
          ComicImportIssueKind.noValidComics => 'No valid comics found'.tl,
          ComicImportIssueKind.scanFailed => issue.error.toString(),
          ComicImportIssueKind.copyRecoveryRequired =>
            'Copy recovery could not finish. The files were kept.'.tl,
          ComicImportIssueKind.copyFailed => 'Failed to copy comics'.tl,
          ComicImportIssueKind.registrationFailed =>
            'Failed to register comics'.tl,
          ComicImportIssueKind.archiveFailed => null,
        };
        if (message != null) presentation.showMessage(message: message);
        final error = issue.error;
        if (error != null) {
          Log.error('Import Comic', error, issue.stackTrace);
        }
      }
      if (result.succeeded) {
        presentation.showMessage(
          message: 'Imported @a comics'.tlParams({'a': result.importedCount}),
        );
      }
      if (result.pendingCopies.isNotEmpty) {
        presentation.showMessage(
          message: 'Some copied comics still need recovery'.tl,
        );
      }
      return result.succeeded;
    } on LocalComicStorageBusy catch (error) {
      presentation.showMessage(message: error.message.tl);
      return false;
    }
  }
}
