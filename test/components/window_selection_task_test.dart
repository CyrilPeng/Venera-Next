import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/favorites/create_favorite_folder_dialog.dart';
import 'package:venera_next/features/local_comics/import_export/import_comic.dart';
import 'package:venera_next/features/local_comics/import_export/import_presentation.dart';
import 'package:venera_next/features/local_comics/import_export/pdf_import_batch.dart';
import 'package:venera_next/features/local_comics/import_export/pdf_import_tasks.dart';
import 'package:venera_next/features/settings/settings_task_presenter.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:window_manager/window_manager.dart';

import 'sidebar_presentation_test.dart' show settleSidebarWork;

class _File extends FileSelection {
  _File({this.release}) : super('selected.pdf');
  final Future<void> Function()? release;
  int prepares = 0;
  int releases = 0;
  @override
  Future<File> prepare() async {
    prepares++;
    return File(identifier);
  }

  @override
  Future<void> dispose() async {
    releases++;
    await release?.call();
  }
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(ready(), isTrue);
}

class _Host {
  _Host({this.registry, this.window = true});
  final SelectionTaskRegistry? registry;
  final bool window;
  final navigator = GlobalKey<NavigatorState>();
  late BuildContext context;
  int exits = 0;
  Widget app({Widget? child}) => MaterialApp(
    navigatorKey: navigator,
    builder: (_, child) {
      final body = window ? WindowFrame(child!, onExit: () => exits++) : child!;
      return registry == null
          ? body
          : SelectionTasksScope(registry: registry!, child: body);
    },
    home: Builder(
      builder: (owner) {
        context = owner;
        return Scaffold(body: child);
      },
    ),
  );
  void close(WidgetTester tester) =>
      (tester.state(find.byType(WindowFrame)) as WindowListener)
          .onWindowClose();
}

void main() {
  setUp(() {
    final muted = Log.isMuted;
    Log.isMuted = true;
    addTearDown(() => Log.isMuted = muted);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (_) async => false,
        );
  });
  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/file_selector'),
      null,
    );
  });

  for (final report in [false, true]) {
    testWidgets(
      'pending consumer failure belongs to closing host: opt-in=$report',
      (tester) async {
        final registry = SelectionTaskRegistry();
        final host = _Host(registry: registry, window: false);
        await tester.pumpWidget(host.app());
        final task = WindowSelectionTask(host.context);
        final pending = Completer<void>();
        final original = StateError('original consumer failure');
        final stack = StackTrace.fromString('original consumer stack');
        var calls = 0;
        Object? operationError;
        final result = task
            .run<void>((_) async {
              calls++;
              await pending.future;
              Error.throwWithStackTrace(original, stack);
            }, reportFailureOnClose: report)
            .catchError((Object error) {
              operationError = error;
            });
        addTearDown(() async {
          if (!pending.isCompleted) pending.complete();
          await settleSidebarWork(tester, () => result);
          await settleSidebarWork(tester, registry.closeAndWait);
        });
        await tester.pump();
        Object? closeError;
        var closed = false;
        final closing = registry.closeAndWait().then<void>(
          (_) => closed = true,
          onError: (Object error) {
            closeError = error;
          },
        );
        await tester.pump();
        expect(closed, isFalse);
        expect(closeError, isNull);
        pending.complete();
        await settleSidebarWork(tester, () => Future.wait([result, closing]));
        expect(operationError, same(original));
        if (report) {
          final failure =
              (closeError as SelectionCleanupFailure).failures.single
                  as ({Object error, StackTrace stack});
          expect(failure.error, same(original));
          expect(failure.stack, same(stack));
        } else {
          expect(closeError, isNull);
          expect(closed, isTrue);
        }
        await settleSidebarWork(tester, registry.closeAndWait);
        expect(calls, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'opt-in close before consumer starts remains expected cancellation',
    (tester) async {
      final registry = SelectionTaskRegistry();
      final host = _Host(registry: registry, window: false);
      await tester.pumpWidget(host.app());
      final task = WindowSelectionTask(host.context);
      var calls = 0;
      Object? reported;
      final result = task
          .run<void>((_) async {
            calls++;
          }, reportFailureOnClose: true)
          .catchError((Object error) {
            reported = error;
          });
      final closing = registry.closeAndWait();
      await settleSidebarWork(tester, () => Future.wait([result, closing]));
      expect(reported, isA<SelectionCancelled>());
      expect(calls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'independent view cleanup retains stacks and original cause across host retries',
    (tester) async {
      final registry = SelectionTaskRegistry();
      final host = _Host(registry: registry, window: false);
      await tester.pumpWidget(host.app());
      final task = WindowSelectionTask(host.context);
      final cause = StateError('import failed');
      final causeStack = StackTrace.fromString('import origin');
      final errors = [StateError('first view'), StateError('second view')];
      final stacks = [
        StackTrace.fromString('first view origin'),
        StackTrace.fromString('second view origin'),
      ];
      final calls = [0, 0, 0];
      final fails = [true, true];
      var operations = 0;
      final result = task.run<void>((_) async {
        operations++;
        for (var i = 0; i < 3; i++) {
          task.retainPresentation(() {
            calls[i]++;
            if (i < 2 && fails[i]) {
              Error.throwWithStackTrace(errors[i], stacks[i]);
            }
          });
        }
        Error.throwWithStackTrace(cause, causeStack);
      });
      SelectionCleanupFailure? failure;
      final observed = result.catchError((Object error) {
        failure = error as SelectionCleanupFailure;
      });
      await tester.pumpAndSettle();
      await observed;
      expect(failure!.operationError, same(cause));
      expect(failure!.operationStack, same(causeStack));
      expect(calls, [1, 1, 1]);
      final initial = failure!.failures
          .cast<({Object error, StackTrace stack})>();
      expect(initial.map((e) => e.error), errors);
      expect(initial.map((e) => e.stack), stacks);
      await tester.pumpWidget(const SizedBox());
      fails[0] = false;
      final closing = registry.closeAndWait();
      SelectionCleanupFailure? hostFailure;
      final failedClose = closing.catchError((Object error) {
        hostFailure = error as SelectionCleanupFailure;
      });
      await tester.pumpAndSettle();
      await failedClose;
      final retained =
          (hostFailure!.failures.single as ({Object error, StackTrace stack}))
                  .error
              as SelectionCleanupFailure;
      expect(retained.operationError, same(cause));
      expect(retained.operationStack, same(causeStack));
      final remaining =
          retained.failures.single as ({Object error, StackTrace stack});
      expect(remaining.error, same(errors[1]));
      expect(remaining.stack, same(stacks[1]));
      expect(calls, [2, 2, 1]);
      fails[1] = false;
      final retry = registry.closeAndWait();
      await tester.pumpAndSettle();
      await retry;
      expect(calls, [2, 3, 1]);
      expect(operations, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cancellation and completion share failed view close until explicit retry',
    (tester) async {
      final host = _Host();
      await tester.pumpWidget(host.app());
      final task = WindowSelectionTask(host.context);
      final finish = Completer<void>();
      var closes = 0;
      var fails = true;
      final result = task.run((_) async {
        task.retainPresentation(() {
          closes++;
          if (fails) throw StateError('view close');
        });
        await finish.future;
      });
      final expected = expectLater(
        result,
        throwsA(isA<SelectionCleanupFailure>()),
      );
      await tester.pump();
      task.cancel();
      await tester.pump();
      task.cancel();
      finish.complete();
      await tester.pumpAndSettle();
      await expected;
      expect(closes, 1);
      fails = false;
      final retry = task.closeAndWait();
      await tester.pumpAndSettle();
      await retry;
      expect(closes, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'window close reports failed presentation before an explicit retry',
    (tester) async {
      final host = _Host();
      await tester.pumpWidget(host.app());
      final task = WindowSelectionTask(host.context);
      final finished = Completer<void>();
      final original = StateError('original view close failed');
      final originalStack = StackTrace.fromString('original view close stack');
      var closes = 0;
      var fails = true;
      Object? operationError;
      final result = task
          .run<void>((_) async {
            task.retainPresentation(() {
              closes++;
              if (!finished.isCompleted) finished.complete();
              if (fails) Error.throwWithStackTrace(original, originalStack);
            });
            await finished.future;
          })
          .catchError((Object error) {
            operationError = error;
          });
      addTearDown(() async {
        fails = false;
        if (!finished.isCompleted) finished.complete();
        await settleSidebarWork(tester, task.closeAndWait);
        await settleSidebarWork(tester, () => result);
      });
      await tester.pump();
      host.close(tester);
      await tester.pumpAndSettle();
      final reported = tester.takeException() as SelectionCleanupFailure;
      final failure =
          reported.failures.single as ({Object error, StackTrace stack});
      expect(failure.error, same(original));
      expect(failure.stack, same(originalStack));
      expect(operationError, isA<SelectionCleanupFailure>());
      expect(host.exits, 0);
      expect(closes, 1);
      fails = false;
      host.close(tester);
      await tester.pumpAndSettle();
      expect(host.exits, 1);
      expect(closes, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'view cleanup keeps concurrent file cleanup failure and its cause',
    (tester) async {
      final host = _Host();
      await tester.pumpWidget(host.app());
      final task = WindowSelectionTask(host.context);
      final cause = StateError('read error');
      var fileFails = true;
      var viewFails = true;
      final file = _File(
        release: () async {
          if (fileFails) throw StateError('file cleanup');
        },
      );
      final result = task.run((owner) async {
        task.retainPresentation(() {
          if (viewFails) throw StateError('view cleanup');
        });
        await owner.pickFile(() async => file);
        throw cause;
      });
      final expected = expectLater(
        result,
        throwsA(
          isA<SelectionCleanupFailure>().having(
            (e) => e.operationError,
            'file failure',
            isA<SelectionCleanupFailure>().having(
              (e) => e.operationError,
              'read cause',
              same(cause),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await expected;
      viewFails = false;
      final failedClose = expectLater(
        task.closeAndWait(),
        throwsA(
          isA<SelectionCleanupFailure>().having(
            (e) => e.operationError,
            'cause',
            same(cause),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await failedClose;
      fileFails = false;
      final retry = task.closeAndWait();
      await tester.pumpAndSettle();
      await retry;
      expect(file.releases, 3);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'synchronous picker close reentry waits for late selection cleanup',
    (tester) async {
      final host = _Host();
      await tester.pumpWidget(host.app());
      final task = WindowSelectionTask(host.context);
      final window = tester.state(find.byType(WindowFrame)) as WindowListener;
      final selected = Completer<FileSelection?>();
      final released = Completer<void>();
      final file = _File(release: () => released.future);
      final result = task.run((owner) async {
        await owner.pickFile(() {
          window.onWindowClose();
          return selected.future;
        });
        fail('late selection consumed');
      });
      final expected = expectLater(result, throwsA(isA<SelectionCancelled>()));
      await tester.pump();
      expect(host.exits, 0);
      selected.complete(file);
      await _until(tester, () => file.releases == 1);
      expect(file.prepares, 0);
      expect(host.exits, 0);
      released.complete();
      await _until(tester, () => host.exits == 1);
      await expected;
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'settings close drains accepted write and cleanup without success callback',
    (tester) async {
      final host = _Host();
      await tester.pumpWidget(host.app());
      final presenter = SettingsTaskPresenter();
      final write = Completer<void>();
      final release = Completer<void>();
      final file = _File(release: () => release.future);
      var writing = false;
      var committed = 0;
      var updates = 0;
      final work = presenter.run(
        host.context,
        task: (owner) async {
          await owner.pickFile(() async => file);
          await owner.useFile(file, (_) async {
            writing = true;
            await write.future;
            committed++;
          });
          return null;
        },
        errorMessage: 'Failed',
        onSuccess: () => updates++,
      );
      await _until(tester, () => writing);
      host.close(tester);
      await tester.pump();
      expect(host.exits, 0);
      expect(file.releases, 0);
      write.complete();
      await _until(tester, () => file.releases == 1);
      expect(host.exits, 0);
      release.complete();
      await _until(tester, () => host.exits == 1);
      await work;
      expect(committed, 1);
      expect(updates, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed cleanup survives removed page and retries only release', (
    tester,
  ) async {
    final host = _Host();
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    late BuildContext page;
    await tester.pumpWidget(
      host.app(
        child: ValueListenableBuilder<bool>(
          valueListenable: visible,
          builder: (_, show, _) => show
              ? Builder(
                  builder: (context) {
                    page = context;
                    return const Text('Owner');
                  },
                )
              : const Text('Removed'),
        ),
      ),
    );
    final task = WindowSelectionTask(page);
    var failRelease = true;
    var attempts = 0;
    final cause = StateError('read failed');
    final file = _File(
      release: () async {
        if (failRelease) throw StateError('release failed');
      },
    );
    await expectLater(
      task.run((owner) async {
        attempts++;
        await owner.pickFile(() async => file);
        throw cause;
      }),
      throwsA(
        isA<SelectionCleanupFailure>().having(
          (e) => e.operationError,
          'cause',
          same(cause),
        ),
      ),
    );
    visible.value = false;
    await tester.pumpAndSettle();
    host.close(tester);
    await tester.pumpAndSettle();
    expect(host.exits, 0);
    expect(tester.takeException(), isNotNull);
    failRelease = false;
    host.close(tester);
    await _until(tester, () => host.exits == 1);
    expect(attempts, 1);
    expect(file.releases, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('favorite import close during read never starts JSON commit', (
    tester,
  ) async {
    final host = _Host();
    final read = Completer<String>();
    final release = Completer<void>();
    final file = _File(release: () => release.future);
    var reading = false;
    var imports = 0;
    await tester.pumpWidget(
      host.app(
        child: CreateFavoriteFolderDialog(
          validate: (_) => null,
          create: (_) {},
          selectImport: (owner) async {
            await owner.pickFile(() async => file);
            return owner.useFile(file, (_) {
              reading = true;
              return read.future;
            });
          },
          importJson: (_) => imports++,
        ),
      ),
    );
    await tester.tap(find.text('Import from file'));
    await _until(tester, () => reading);
    host.close(tester);
    read.complete('{}');
    await _until(tester, () => file.releases == 1);
    expect(host.exits, 0);
    expect(imports, 0);
    release.complete();
    await _until(tester, () => host.exits == 1);
    expect(imports, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'real EhViewer entry rejects late database before second dialog',
    (tester) async {
      final host = _Host();
      await tester.pumpWidget(host.app());
      final task = WindowSelectionTask(host.context);
      final selected = Completer<List<String>?>();
      var dialogs = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/file_selector'),
            (call) {
              dialogs++;
              expectSync(call.method, 'openFile');
              return selected.future;
            },
          );
      final result = task.run((owner) => const ImportComic().ehViewer(owner));
      final expected = expectLater(result, throwsA(isA<SelectionCancelled>()));
      await _until(tester, () => dialogs == 1);
      host.close(tester);
      selected.complete(['selected.db']);
      await _until(tester, () => host.exits == 1);
      await expected;
      expect(dialogs, 1);
      await tester.pump(const Duration(milliseconds: 120));
      expect(IO.isSelectingFiles, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'queued file picker checks cancellation before opening native dialog',
    (tester) async {
      final selected = Completer<String?>();
      var dialogs = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/file_selector'),
            (_) {
              dialogs++;
              return selected.future;
            },
          );
      final first = selectFile(ext: ['db']);
      await _until(tester, () => dialogs == 1);
      final operation = SelectionOperation();
      final second = operation.run(
        (owner) => owner.pickFiles(
          () => selectFiles(ext: ['pdf'], checkStop: owner.checkActive),
        ),
      );
      final expected = expectLater(second, throwsA(isA<SelectionCancelled>()));
      await tester.pump();
      operation.cancel();
      selected.complete(null);
      await tester.pump();
      expect(await first, isNull);
      await expected;
      expect(dialogs, 1);
      await tester.pump(const Duration(milliseconds: 120));
      expect(IO.isSelectingFiles, isFalse);
    },
  );

  testWidgets('covered page releases late selection without consuming it', (
    tester,
  ) async {
    final host = _Host();
    await tester.pumpWidget(host.app());
    final task = WindowSelectionTask(host.context);
    final selected = Completer<FileSelection?>();
    final file = _File();
    final work = task.run((owner) async {
      final value = await owner.pickFile(() => selected.future);
      await owner.useFile(value!, (_) async => fail('covered page consumer'));
    });
    final expected = expectLater(work, throwsA(isA<SelectionCancelled>()));
    await tester.pump();
    host.navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Replacement')),
      ),
    );
    await tester.pumpAndSettle();
    selected.complete(file);
    await tester.pumpAndSettle();
    await expected;
    expect(file.prepares, 0);
    expect(file.releases, 1);
    expect(find.text('Replacement'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'removing owner beneath progress closes only its route outside Navigator lock',
    (tester) async {
      final host = _Host();
      await tester.pumpWidget(host.app());
      WindowSelectionTask? task;
      late BuildContext page;
      final route = MaterialPageRoute<void>(
        builder: (context) {
          page = context;
          return DialogResourceScope(
            onDispose: () => task?.cancel(),
            child: const Scaffold(body: Text('Owner')),
          );
        },
      );
      host.navigator.currentState!.push(route);
      await tester.pumpAndSettle();
      final owner = task = WindowSelectionTask(page);
      final pending = Completer<void>();
      final work = owner.run((_) async {
        ImportComicPresentation.forTask(owner).showLoading(allowCancel: false);
        await pending.future;
      });
      await _until(
        tester,
        () => find.byType(LinearProgressIndicator).evaluate().isNotEmpty,
      );
      host.navigator.currentState!.removeRoute(route);
      await tester.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(owner.canPresent, isFalse);
      pending.complete();
      await tester.pumpAndSettle();
      await work;
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'application registry retains cleanup after a host without WindowFrame unmounts',
    (tester) async {
      final registry = SelectionTaskRegistry();
      final host = _Host(registry: registry, window: false);
      await tester.pumpWidget(host.app());
      final owner = WindowSelectionTask(host.context);
      var fails = true;
      final file = _File(
        release: () async {
          if (fails) throw StateError('native release failed');
        },
      );
      var operations = 0;
      final result = owner.run((operation) async {
        operations++;
        await operation.pickFile(() async => file);
      });
      final expected = expectLater(
        result,
        throwsA(isA<SelectionCleanupFailure>()),
      );
      await tester.pumpAndSettle();
      await expected;
      await tester.pumpWidget(const SizedBox());
      final closing = registry.closeAndWait();
      final failedClose = expectLater(
        closing,
        throwsA(isA<SelectionCleanupFailure>()),
      );
      await tester.pumpAndSettle();
      await failedClose;
      fails = false;
      final retry = registry.closeAndWait();
      await tester.pumpAndSettle();
      await retry;
      expect(operations, 1);
      expect(file.releases, 3);
      expect(registry.isClosing, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'PDF view closes on exit while transferred batch drains separately',
    (tester) async {
      final host = _Host();
      await tester.pumpWidget(host.app());
      final tasks = PdfImportTasks();
      addTearDown(tasks.dispose);
      WindowFrame.of(host.context).addExitTask(() async {
        await tasks.prepareForExit();
      });
      final task = WindowSelectionTask(host.context);
      final release = Completer<void>();
      final write = Completer<void>();
      final file = _File(release: () => release.future);
      var importing = false;
      final work = task.run((owner) async {
        final files = await owner.pickFiles(() async => [file]);
        final pdf = owner.transferFiles(
          files,
          () => tasks.add(
            files: files,
            batch: PdfImportBatch(
              containsTitle: (_) => false,
              importFile: (_, _, _, cancellation) async {
                importing = true;
                await write.future;
                cancellation.throwIfCancelled();
              },
            ),
          ),
        );
        await ImportComicPresentation.forTask(task).showPdfTask(pdf);
      });
      await _until(tester, () => importing);
      host.close(tester);
      await tester.pump();
      expect(host.exits, 0);
      expect(task.operation.hasPendingCleanup, isFalse);
      write.complete();
      await _until(tester, () => file.releases == 1);
      expect(host.exits, 0);
      release.complete();
      await _until(tester, () => host.exits == 1);
      await work;
      expect(tasks.tasks.single.isFinished, isTrue);
      expect(file.releases, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
