import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/favorites/create_favorite_folder_dialog.dart';
import 'package:venera_next/foundation/file_selection.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/persistence_failure.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:window_manager/window_manager.dart';

import '../../components/sidebar_presentation_test.dart'
    show pumpSidebar, settleSidebarWork, sidebarCauses;

class _Selection extends FileSelection {
  _Selection() : super('synthetic-favorite.json');
  bool fails = true;
  int releases = 0;
  final failure = StateError('original selected file release');
  @override
  Future<void> dispose() async {
    releases++;
    if (fails) throw failure;
  }
}

class _Host {
  final navigator = GlobalKey<NavigatorState>();
  final registry = SelectionTaskRegistry();
  String? Function(String) validate = (_) => null;
  FutureOr<void> Function(String) create = (_) {};
  Future<String?> Function(SelectionOperation) selectImport = (_) async => '{}';
  FutureOr<void> Function(String) importJson = (_) {};
  late Route<void> dialog;
  bool window = false;
  int exits = 0;
  double textScale = 1;
  Brightness brightness = Brightness.light;

  Widget app({SelectionTaskRegistry? registry}) => MaterialApp(
    navigatorKey: navigator,
    theme: ThemeData(brightness: brightness),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
        disableAnimations: true,
      ),
      child: SelectionTasksScope(
        registry: registry ?? this.registry,
        child: window ? WindowFrame(child!, onExit: () => exits++) : child!,
      ),
    ),
    home: const Scaffold(body: Text('Original home')),
  );

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(app());
    dialog = MaterialPageRoute<void>(
      builder: (_) => CreateFavoriteFolderDialog(
        validate: validate,
        create: create,
        selectImport: selectImport,
        importJson: importJson,
      ),
    );
    navigator.currentState!.push(dialog);
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await pumpSidebar(tester);
      await settleSidebarWork(tester, registry.closeAndWait);
    });
  }

  Route<void> cover() {
    final newer = MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('Newer page')),
    );
    navigator.currentState!.push(newer);
    return newer;
  }
}

VoidCallback confirm(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byType(FilledButton)).onPressed!;

VoidCallback importAction(WidgetTester tester) => tester
    .widget<TextButton>(find.widgetWithText(TextButton, 'Import from file'))
    .onPressed!;

void main() {
  setUp(() {
    final muted = Log.isMuted;
    Log.isMuted = true;
    addTearDown(() => Log.isMuted = muted);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (_) async => false,
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        null,
      );
    });
  });

  testWidgets('validation reentry cannot create a folder twice', (
    tester,
  ) async {
    final host = _Host();
    var validations = 0;
    final names = <String>[];
    late VoidCallback retained;
    host.validate = (_) {
      if (++validations == 1) retained();
      return null;
    };
    host.create = names.add;
    await host.mount(tester);
    await tester.enterText(find.byType(TextField), 'Original');
    retained = confirm(tester);
    retained();
    await pumpSidebar(tester);
    expect(validations, 1);
    expect(names, ['Original']);
    expect(host.dialog.isActive, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('creation uses the same draft that validation received', (
    tester,
  ) async {
    final host = _Host();
    final validated = <String>[];
    final created = <String>[];
    late TextEditingController controller;
    host.validate = (name) {
      validated.add(name);
      controller.text = 'Changed during validation';
      return null;
    };
    host.create = created.add;
    await host.mount(tester);
    await tester.enterText(find.byType(TextField), 'Original');
    controller = tester.widget<TextField>(find.byType(TextField)).controller!;
    confirm(tester)();
    await pumpSidebar(tester);
    expect(validated, ['Original']);
    expect(created, ['Original']);
    expect(host.dialog.isActive, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('covered completed creation is acknowledged without replay', (
    tester,
  ) async {
    final host = _Host();
    final pending = Completer<void>();
    var creates = 0;
    host.create = (_) {
      creates++;
      return pending.future;
    };
    await host.mount(tester);
    addTearDown(() {
      if (!pending.isCompleted) pending.complete();
    });
    await tester.enterText(find.byType(TextField), 'Original');
    confirm(tester)();
    await tester.pump();
    final newer = host.cover();
    await pumpSidebar(tester);
    pending.complete();
    await pumpSidebar(tester);
    expect(newer.isCurrent, isTrue);
    expect(creates, 1);
    host.navigator.currentState!.pop();
    await pumpSidebar(tester);
    confirm(tester)();
    await pumpSidebar(tester);
    expect(creates, 1);
    expect(host.dialog.isActive, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('covered completed import cannot replay a retained action', (
    tester,
  ) async {
    final host = _Host();
    final pending = Completer<void>();
    var reads = 0;
    var imports = 0;
    var creates = 0;
    host.selectImport = (_) async {
      reads++;
      return '{}';
    };
    host.importJson = (_) {
      imports++;
      return pending.future;
    };
    host.create = (_) => creates++;
    await host.mount(tester);
    addTearDown(() {
      if (!pending.isCompleted) pending.complete();
    });
    final retained = importAction(tester);
    retained();
    await tester.pump();
    final newer = host.cover();
    await pumpSidebar(tester);
    expect(imports, 1);
    pending.complete();
    await pumpSidebar(tester);
    expect(newer.isCurrent, isTrue);
    host.navigator.currentState!.pop();
    await pumpSidebar(tester);
    retained();
    await pumpSidebar(tester);
    expect(reads, 1);
    expect(imports, 1);
    confirm(tester)();
    await pumpSidebar(tester);
    expect(creates, 0);
    expect(host.dialog.isActive, isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final state in PersistenceCommitState.values) {
    testWidgets('create retry respects the original commit state: $state', (
      tester,
    ) async {
      final host = _Host();
      var creates = 0;
      host.create = (_) {
        if (++creates == 1) {
          throw PersistenceFailure(
            commitState: state,
            cause: StateError('original create failure'),
            stackTrace: StackTrace.current,
          );
        }
      };
      await host.mount(tester);
      await tester.enterText(find.byType(TextField), 'Original');
      confirm(tester)();
      await pumpSidebar(tester);
      expect(host.dialog.isActive, isTrue);
      expect(find.textContaining('original create failure'), findsOneWidget);
      confirm(tester)();
      await pumpSidebar(tester);
      expect(creates, state == PersistenceCommitState.notCommitted ? 2 : 1);
      expect(host.dialog.isActive, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('import retry respects the original commit state: $state', (
      tester,
    ) async {
      final host = _Host();
      var reads = 0;
      var imports = 0;
      var creates = 0;
      host.selectImport = (_) async {
        reads++;
        return '{}';
      };
      host.create = (_) => creates++;
      host.importJson = (_) {
        if (++imports == 1) {
          throw PersistenceFailure(
            commitState: state,
            cause: StateError('original import failure'),
            stackTrace: StackTrace.current,
          );
        }
      };
      await host.mount(tester);
      final retained = importAction(tester);
      retained();
      await pumpSidebar(tester);
      expect(host.dialog.isActive, isTrue);
      retained();
      await pumpSidebar(tester);
      final expected = state == PersistenceCommitState.notCommitted ? 2 : 1;
      expect(reads, expected);
      expect(imports, expected);
      if (state != PersistenceCommitState.notCommitted) {
        confirm(tester)();
        await pumpSidebar(tester);
      }
      expect(creates, 0);
      expect(host.dialog.isActive, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  for (final state in [
    null,
    PersistenceCommitState.committed,
    PersistenceCommitState.unknown,
  ]) {
    testWidgets(
      'import cleanup retry cannot replay a committed write: $state',
      (tester) async {
        final host = _Host();
        final file = _Selection();
        var reads = 0;
        var imports = 0;
        host.selectImport = (operation) async {
          reads++;
          await operation.pickFile(() async => file);
          return '{}';
        };
        host.importJson = (_) {
          imports++;
          if (state != null) {
            throw PersistenceFailure(
              commitState: state,
              cause: StateError('original import commit'),
              stackTrace: StackTrace.current,
            );
          }
        };
        await host.mount(tester);
        addTearDown(() => file.fails = false);
        final retained = importAction(tester);
        retained();
        await pumpSidebar(tester);
        expect(file.releases, 1);
        expect(imports, 1);
        expect(find.text('Failed to import'), findsOneWidget);
        expect(find.widgetWithText(FilledButton, 'OK'), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byType(TextField)).enabled,
          isFalse,
        );
        expect(
          tester
              .widget<TextButton>(
                find.widgetWithText(TextButton, 'Import from file'),
              )
              .onPressed,
          isNull,
        );
        retained();
        confirm(tester)();
        await pumpSidebar(tester);
        expect(host.dialog.isActive, isFalse);
        expect((reads, imports, file.releases), (1, 1, 1));
        Object? failure;
        await settleSidebarWork(
          tester,
          () => host.registry.closeAndWait().catchError((Object error) {
            failure = error;
          }),
        );
        final retainedFailure = sidebarCauses(
          failure!,
        ).whereType<FileSelectionCleanupFailure>().single;
        expect(retainedFailure.cleanupError, same(file.failure));
        if (state != null) {
          expect(
            retainedFailure.operationError,
            isA<PersistenceFailure>().having(
              (failure) => failure.commitState,
              'original commit state',
              state,
            ),
          );
        }
        expect(file.releases, 2);
        file.fails = false;
        await settleSidebarWork(tester, host.registry.closeAndWait);
        expect((reads, imports, file.releases), (1, 1, 3));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'shutdown during validation rejects creation after registration',
    (tester) async {
      final host = _Host();
      var created = 0;
      Future<void>? closing;
      host.validate = (_) {
        closing = host.registry.closeAndWait();
        return null;
      };
      host.create = (_) => created++;
      await host.mount(tester);
      confirm(tester)();
      await pumpSidebar(tester);
      expect(closing, isNotNull);
      await settleSidebarWork(tester, () => closing!);
      expect(created, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'accepted creation stays with its original application registry',
    (tester) async {
      final host = _Host();
      final pending = Completer<void>();
      var creates = 0;
      host.create = (_) {
        creates++;
        return pending.future;
      };
      await host.mount(tester);
      addTearDown(() {
        if (!pending.isCompleted) pending.complete();
      });
      final retained = confirm(tester);
      retained();
      await tester.pump();
      final replacement = SelectionTaskRegistry();
      await tester.pumpWidget(host.app(registry: replacement));
      var originalClosed = false;
      final originalClosing = host.registry.closeAndWait().then(
        (_) => originalClosed = true,
      );
      await settleSidebarWork(tester, replacement.closeAndWait);
      expect(originalClosed, isFalse);
      retained();
      pending.complete();
      await settleSidebarWork(tester, () => originalClosing);
      retained();
      await pumpSidebar(tester);
      expect(creates, 1);
      expect(host.dialog.isActive, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('window joins accepted creation after its dialog is dismissed', (
    tester,
  ) async {
    final host = _Host()..window = true;
    final pending = Completer<void>();
    host.create = (_) => pending.future;
    await host.mount(tester);
    addTearDown(() {
      if (!pending.isCompleted) pending.complete();
    });
    confirm(tester)();
    await tester.pump();
    host.navigator.currentState!.pop();
    await pumpSidebar(tester);
    (tester.state(find.byType(WindowFrame)) as WindowListener).onWindowClose();
    await pumpSidebar(tester);
    expect(host.exits, 0);
    pending.completeError(StateError('late original create failure'));
    await pumpSidebar(tester);
    expect(host.exits, 1);
    expect(tester.takeException(), isNull);
  });

  for (final importing in [false, true]) {
    testWidgets(
      'covered commit failure remains visible on return: import=$importing',
      (tester) async {
        final host = _Host();
        final pending = Completer<void>();
        var writes = 0;
        Future<void> write(String _) {
          writes++;
          return pending.future;
        }

        host.create = write;
        host.importJson = write;
        await host.mount(tester);
        addTearDown(() {
          if (!pending.isCompleted) pending.complete();
        });
        final retained = importing ? importAction(tester) : confirm(tester);
        retained();
        await tester.pump();
        final newer = host.cover();
        await pumpSidebar(tester);
        pending.completeError(
          PersistenceFailure(
            commitState: PersistenceCommitState.unknown,
            cause: StateError('original late create failure'),
            stackTrace: StackTrace.current,
          ),
        );
        await pumpSidebar(tester);
        expect(newer.isCurrent, isTrue);
        expect(
          find.textContaining('original late create failure'),
          findsNothing,
        );
        host.navigator.currentState!.pop();
        await pumpSidebar(tester);
        expect(
          importing
              ? find.text('Failed to import')
              : find.textContaining('original late create failure'),
          findsOneWidget,
        );
        expect(find.widgetWithText(FilledButton, 'OK'), findsOneWidget);
        retained();
        if (importing) confirm(tester)();
        await pumpSidebar(tester);
        expect(writes, 1);
        expect(host.dialog.isActive, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final (size, brightness) in [
    (const Size(360, 640), Brightness.light),
    (const Size(900, 500), Brightness.dark),
  ]) {
    testWidgets('creation remains usable with large text: $size $brightness', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final host = _Host()
        ..textScale = 2
        ..brightness = brightness;
      final pending = Completer<void>();
      host.create = (_) => pending.future;
      await host.mount(tester);
      addTearDown(() {
        if (!pending.isCompleted) pending.complete();
      });
      final semantics = tester.ensureSemantics();
      try {
        await tester.enterText(find.byType(TextField), 'Original');
        confirm(tester)();
        await pumpSidebar(tester);
        final button = find.widgetWithText(FilledButton, 'Create');
        expect(tester.widget<FilledButton>(button).onPressed, isNull);
        expect(tester.getSemantics(button).label, contains('Create'));
        expect(tester.takeException(), isNull);
        final newer = host.cover();
        await pumpSidebar(tester);
        pending.complete();
        await pumpSidebar(tester);
        expect(newer.isCurrent, isTrue);
        host.navigator.currentState!.pop();
        await pumpSidebar(tester);
        final ok = find.widgetWithText(FilledButton, 'OK');
        expect(tester.getSemantics(ok).label, contains('OK'));
        await tester.ensureVisible(ok);
        await tester.tap(ok);
        await pumpSidebar(tester);
        expect(host.dialog.isActive, isFalse);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }
}
