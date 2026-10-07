import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/local_comics/import_export/import_comic.dart';
import 'package:venera_next/features/local_comics/import_export/import_presentation.dart';
import 'package:venera_next/features/local_comics/import_export/pdf_import_batch.dart';
import 'package:venera_next/features/local_comics/import_export/pdf_import_tasks.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/local_comics/import_export/comic_directory_copy.dart';
import 'package:venera_next/features/local_comics/import_export/comic_copy_metadata.dart';
import 'package:venera_next/features/local_comics/import_export/comic_copy_record.dart';
import 'package:venera_next/features/local_comics/import_export/copy_recovery_dialog.dart';
import 'package:venera_next/foundation/comic_type.dart';

class _Selection extends FileSelection {
  _Selection() : super.androidDocument(uri: 'test.pdf', name: 'test.pdf');
  int disposed = 0;
  @override
  Future<File> prepare() async => File(name);
  @override
  Future<void> dispose() async {
    disposed++;
  }
}

void main() {
  const presentation = ImportComicPresentation();
  Future<T> withFrames<T>(
    WidgetTester tester,
    Future<T> Function() action,
    String phase,
  ) async {
    var done = false;
    T? value;
    Object? error;
    StackTrace? stack;
    await tester.runAsync(() async {
      unawaited(
        action().then(
          (result) {
            value = result;
            done = true;
          },
          onError: (Object failure, StackTrace trace) {
            error = failure;
            stack = trace;
            done = true;
          },
        ),
      );
    });
    for (var i = 0; i < 150 && !done; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(done, isTrue, reason: phase);
    if (error != null) Error.throwWithStackTrace(error!, stack!);
    return value as T;
  }

  Future<WindowSelectionTask> host(WidgetTester tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: Builder(
          builder: (owner) {
            context = owner;
            return const Scaffold();
          },
        ),
      ),
    );
    return WindowSelectionTask(context);
  }

  testWidgets('presentation tolerates absent root', (tester) async {
    await tester.pumpWidget(const SizedBox());
    presentation.showMessage(message: 'Completed');
    expect(presentation.showLoading(), isNull);
    expect(tester.takeException(), isNull);
  });

  for (final later in [false, true]) {
    testWidgets(
      'actual recovery facade preserves or restores saved favorite intent; later=$later',
      (tester) async {
        final root = Directory.systemTemp.createTempSync(
          'copy-recovery-facade-',
        );
        App.dataPath = root.path;
        App.cachePath = root.path;
        LocalManager.resetForTesting();
        LocalManager.debugSkipComicSourceInit = true;
        final manager = LocalManager();
        LocalFavoritesManager.cache = null;
        final favorites = LocalFavoritesManager();
        final oldFollow = appdata.settings['followUpdatesFolder'];
        final oldQuick = appdata.settings['quickFavorite'];
        final messages = <String>[];
        registerShowMessageHandler((context, message) => messages.add(message));
        try {
          late Directory copied;
          await tester.runAsync(() async {
            await manager.init();
            await favorites.init();
            await favorites.createFolder('Current folder');
            final source = Directory('${root.path}/source')..createSync();
            File('${source.path}/1.jpg').writeAsStringSync('retained pages');
            final comic = LocalComic(
              id: '0',
              title: 'Recovered title',
              subtitle: 'Author',
              tags: ['tag'],
              directory: source.path,
              chapters: null,
              cover: '1.jpg',
              comicType: ComicType.local,
              downloadedChapters: [],
              createdAt: DateTime(2024),
            );
            final result = await copyComicDirectories(
              ComicDirectoryCopyRequest(
                directories: [source.path],
                destination: manager.path,
                metadata: {
                  source.path: encodeComicCopyMetadata(comic, 'Old folder'),
                },
              ),
            );
            copied = Directory(result.copies[source.path]!);
          });
          final task = await host(tester);
          late Future<bool> result;
          await tester.runAsync(() async {
            result = task.run(
              (_) => ImportComic(
                presentation: ImportComicPresentation.forTask(task),
              ).localDownloads(),
            );
          });
          for (
            var i = 0;
            i < 100 && find.byType(ComicCopyRecoveryDialog).evaluate().isEmpty;
            i++
          ) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(find.byType(ComicCopyRecoveryDialog), findsOneWidget);
          await tester.pumpAndSettle();
          expect(manager.count, 0);
          expect(find.text('Recovered title'), findsOneWidget);
          if (later) {
            await tester.tap(find.text('Later'.tl));
          } else {
            await tester.tap(find.text('Current folder'));
            await tester.pump();
            await tester.tap(find.text('Restore'.tl));
          }
          await tester.pumpAndSettle();
          expect(
            await withFrames(tester, () => result, 'recovery result'),
            isTrue,
          );
          expect(manager.count, later ? 0 : 1);
          expect(
            favorites.getFolderComics('Current folder'),
            hasLength(later ? 0 : 1),
          );
          expect(ComicCopyRecord.exists(copied), later);
          expect(
            File('${copied.path}/1.jpg').readAsStringSync(),
            'retained pages',
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await withFrames(tester, () async {
            await favorites.debugWaitForHashedIdsRefresh();
            await appdata.saveData(false);
            await favorites.closeAndWait();
            await manager.pendingDownloadTaskWrites;
          }, 'recovery teardown');
          LocalFavoritesManager.cache = null;
          LocalManager.resetForTesting();
          appdata.settings['followUpdatesFolder'] = oldFollow;
          appdata.settings['quickFavorite'] = oldQuick;
          registerShowMessageHandler((context, message) {});
          root.deleteSync(recursive: true);
        }
      },
    );
  }

  testWidgets(
    'directory facade imports the picked files through the real service',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('import-facade-');
      App.dataPath = root.path;
      App.cachePath = root.path;
      LocalManager.resetForTesting();
      LocalManager.debugSkipComicSourceInit = true;
      final manager = LocalManager();
      await tester.runAsync(manager.init);
      final source = Directory('${root.path}/Picked')..createSync();
      File('${source.path}/1.jpg').writeAsStringSync('page');
      final task = await host(tester);
      final messages = <String>[];
      registerShowMessageHandler((context, message) => messages.add(message));
      const channel = MethodChannel('plugins.flutter.io/file_selector');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getDirectoryPath');
        return source.path;
      });
      try {
        final result = await tester.runAsync(
          () => task.run(
            (operation) => ImportComic(
              presentation: ImportComicPresentation.forTask(task),
            ).directory(true, operation),
          ),
        );
        expect(result, isTrue);
        expect(manager.findByName('Picked'), isNotNull);
        await tester.pumpAndSettle();
        expect(messages, [
          'Imported @a comics'.tlParams({'a': 1}),
        ]);
        expect(tester.takeException(), isNull);
      } finally {
        registerShowMessageHandler((context, message) {});
        messenger.setMockMethodCallHandler(channel, null);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async => manager.pendingDownloadTaskWrites);
        LocalManager.resetForTesting();
        root.deleteSync(recursive: true);
      }
    },
  );

  testWidgets('loading cleanup survives unmount and never adopts a new root', (
    tester,
  ) async {
    final original = ImportComicPresentation.forTask(await host(tester));
    var cancelled = 0;
    final controller = original.showLoading(onCancel: () => cancelled++);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpWidget(const SizedBox());
    expect(controller!.closed, isTrue);
    expect(cancelled, 1);
    controller.setMessage('Late progress');
    controller.setProgress(1);
    controller.close();
    final replacement = ImportComicPresentation.forTask(await host(tester));
    original.showMessage(message: 'Late completion');
    expect(original.showLoading(message: 'Stale'), isNull);
    final next = replacement.showLoading(
      message: 'New import',
      allowCancel: false,
    );
    await tester.pump();
    expect(find.text('New import'), findsOneWidget);
    next!.close();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final visible in [false, true]) {
    testWidgets(
      'PDF view finishes without cancelling app task; visible=$visible',
      (tester) async {
        final tasks = PdfImportTasks();
        final gate = Completer<void>();
        final file = _Selection();
        final task = tasks.add(
          files: [file],
          batch: PdfImportBatch(
            containsTitle: (_) => false,
            importFile: (_, title, progress, cancellation) async {
              await gate.future;
              cancellation.throwIfCancelled();
            },
          ),
        );
        addTearDown(tasks.dispose);
        var selectedPresentation = presentation;
        if (visible) {
          selectedPresentation = ImportComicPresentation.forTask(
            await host(tester),
          );
        } else {
          await tester.pumpWidget(const SizedBox());
        }
        var viewClosed = false;
        final view = selectedPresentation
            .showPdfTask(task)
            .then((_) => viewClosed = true);
        await tester.pump();
        if (visible) {
          await tester.pump(const Duration(milliseconds: 400));
          expect(viewClosed, isFalse);
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
        }
        await tester.pump();
        expect(viewClosed, isTrue);
        await view;
        expect(viewClosed, isTrue);
        expect(task.isFinished, isFalse);
        expect(task.isCancelling, isFalse);
        gate.complete();
        await tester.pump();
        expect(task.isFinished, isTrue);
        final result = await task.done;
        expect(result.count(PdfImportStatus.imported), 1);
        expect(file.disposed, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
