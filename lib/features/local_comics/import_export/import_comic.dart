import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/components/message.dart'
    show LoadingDialogController;
import '../local_storage_guard.dart';
import 'cbz.dart';
import 'comic_import_service.dart';
import 'comic_collection_archive.dart';
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
    if (App.isHarmonyOS) {
      final files = await operation.pickFiles(
        () => selectFiles(
          ext: ['cbz', 'zip', '7z', 'cb7'],
          checkStop: operation.checkActive,
        ),
      );
      if (files.isEmpty) return false;
      final controller = presentation.showLoading(allowCancel: false);
      try {
        return await _showImportResult(
          () => service.selectedArchives(
            files,
            folder: selectedFolder,
            checkStop: operation.checkActive,
          ),
        );
      } finally {
        controller?.close();
      }
    }
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
      () => DirectoryPicker().pickDirectory(
        copyForImport: true,
        checkStop: operation.checkActive,
      ),
    );
    if (directory == null) return false;
    return _showImportResult(
      () => service.runImport((importing) async {
        if (!copyToLocal && !App.isHarmonyOS) {
          await directory.retainAccessForSession();
        }
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
                copy: copyToLocal || App.isHarmonyOS,
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
    LoadingDialogController? controller;
    final selection = await operation.pickDirectory(
      () => DirectoryPicker().pickDirectory(
        copyForImport: true,
        checkStop: operation.checkActive,
        onCopyProgress: (processed, total) =>
            controller?.setProgress(total > 0 ? processed / total : null),
      ),
    );
    if (selection == null) return false;
    controller = presentation.showLoading(
      allowCancel: false,
      message: 'Preparing selected folder'.tl,
    );
    try {
      return await _showImportResult(
        () => service.runImport((importing) async {
          if (!copyToLocal && !App.isHarmonyOS) {
            await selection.retainAccessForSession();
          }
          operation.checkActive();
          return operation.useDirectory(selection, (directory) {
            controller?.setProgress(null);
            controller?.setMessage('Scanning and importing comics'.tl);
            return importing.directory(
              directory,
              single: single,
              copy: copyToLocal || App.isHarmonyOS,
              folder: selectedFolder,
              onScanProgress: (count) => controller?.setMessage(
                'Scanned @a folders; preparing import'.tlParams({'a': count}),
              ),
              onScanComplete: () =>
                  controller?.setMessage('Saving imported comics'.tl),
            );
          });
        }),
        persistent: App.isHarmonyOS,
        beforeResult: () => controller?.close(),
      );
    } finally {
      controller?.close();
    }
  }

  Future<bool> collectionArchive(SelectionOperation operation) async {
    final file = await operation.pickFile(
      () => selectFile(ext: ['zip'], checkStop: operation.checkActive),
    );
    if (file == null) return false;
    final controller = presentation.showLoading(
      allowCancel: false,
      message: 'Extracting comic collection'.tl,
    );
    try {
      return await _showImportResult(
        () => service.runImport(
          (importing) => operation.useFile(file, (source) {
            return operation.useTemporaryDirectory(
              cacheDirectory: Directory(App.cachePath),
              prepare: (workspace) async {
                if ((await CBZ.checkType(source)).mime != 'application/zip') {
                  throw const FormatException(
                    'The collection must be a ZIP file',
                  );
                }
                await extractComicCollection(source, workspace);
              },
              consume: (workspace) async {
                controller?.setMessage('Scanning and importing comics'.tl);
                return importing.directory(
                  workspace,
                  single: false,
                  copy: true,
                  folder: selectedFolder,
                  onScanProgress: (count) => controller?.setMessage(
                    'Scanned @a folders; preparing import'.tlParams({
                      'a': count,
                    }),
                  ),
                  onScanComplete: () =>
                      controller?.setMessage('Saving imported comics'.tl),
                );
              },
            );
          }),
        ),
        persistent: true,
        beforeResult: () => controller?.close(),
      );
    } finally {
      controller?.close();
    }
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
      if (!presentation.canPresent) break;
      final favorites = await service.runRecovery(
        (operation) async => operation.copyRecoveryFolders(),
      );
      final choice = await presentation.chooseCopyRecovery(
        title: pending.title,
        previousFolder: pending.folder,
        folders: favorites.folders,
        kind: pending.kind,
      );
      if (choice == null) continue;
      final loading = presentation.showLoading(allowCancel: false);
      late ComicImportResult recovered;
      try {
        recovered = await service.runRecovery(
          (operation) => operation.recoverCopy(
            pending,
            folder: choice.folder,
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
    Future<ComicImportResult> Function() action, {
    bool persistent = false,
    void Function()? beforeResult,
  }) async {
    late final ComicImportResult result;
    try {
      result = await action();
    } on LocalComicStorageBusy catch (error) {
      beforeResult?.call();
      presentation.showMessage(message: error.message.tl);
      return false;
    } on SelectionCancelled {
      rethrow;
    } catch (error, stack) {
      if (!persistent) rethrow;
      result = ComicImportResult(
        succeeded: false,
        issues: [
          ComicImportIssue(ComicImportIssueKind.scanFailed, error, stack),
        ],
      );
    }
    beforeResult?.call();
    try {
      final details = <String>[];
      for (final issue in result.issues) {
        final message = switch (issue.kind) {
          ComicImportIssueKind.invalidComic =>
            issue.error is String
                ? (issue.error as String).tl
                : 'Invalid Comic'.tl,
          ComicImportIssueKind.localPathNotFound => 'Local path not found'.tl,
          ComicImportIssueKind.noValidComics => 'No valid comics found'.tl,
          ComicImportIssueKind.scanFailed =>
            issue.error is FormatException
                ? (issue.error as FormatException).message.tl
                : issue.error.toString(),
          ComicImportIssueKind.copyRecoveryRequired =>
            'Copy recovery could not finish. The files were kept.'.tl,
          ComicImportIssueKind.copyFailed => 'Failed to copy comics'.tl,
          ComicImportIssueKind.registrationFailed =>
            'Failed to register comics'.tl,
          ComicImportIssueKind.archiveFailed =>
            'Failed to import @name: @error'.tlParams({
              'name': issue.sourceName ?? 'Archive'.tl,
              'error': issue.error.toString(),
            }),
          ComicImportIssueKind.directorySkipped =>
            'Skipped @name: @reason'.tlParams({
              'name': issue.sourceName ?? 'Folder'.tl,
              'reason': issue.error is String
                  ? (issue.error as String).tl
                  : issue.error.toString(),
            }),
        };
        details.add(message);
        if (!persistent) presentation.showMessage(message: message);
        final error = issue.error;
        if (error != null) {
          Log.error(
            'Import Comic',
            issue.sourceName == null ? error : '${issue.sourceName}: $error',
            issue.stackTrace,
          );
        }
      }
      final failedArchives = result.issues
          .where((issue) => issue.kind == ComicImportIssueKind.archiveFailed)
          .length;
      if (!persistent && failedArchives > 0) {
        presentation.showMessage(
          message: 'Success: @a, Failed: @b'.tlParams({
            'a': result.importedCount,
            'b': failedArchives,
          }),
        );
      } else if (!persistent && result.succeeded && result.importedCount > 0) {
        presentation.showMessage(
          message: 'Imported @a comics'.tlParams({'a': result.importedCount}),
        );
      }
      if (result.pendingCopies.isNotEmpty) {
        final message = 'Some copied comics still need recovery'.tl;
        if (persistent) {
          details.add(message);
        } else {
          presentation.showMessage(message: message);
        }
      }
      if (persistent) {
        await presentation.showResult(
          imported: result.importedCount,
          details: details,
        );
      }
    } catch (error, stack) {
      if (!persistent) rethrow;
      // Presentation failure cannot turn a committed import into zero success.
      Log.error('Import result presentation', error, stack);
    }
    return result.succeeded;
  }
}
