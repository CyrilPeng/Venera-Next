import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:window_manager/window_manager.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/comic_source/comic_source_manager.dart';
import 'package:venera_next/features/comic_source/comic_source_page.dart';
import 'package:venera_next/features/comic_source/source.dart';
import 'package:venera_next/features/comic_source/source_data_storage.dart';
import 'package:venera_next/features/comic_source/source_mutation_failure.dart';
import 'package:venera_next/features/comic_source/source_installation.dart';
import 'package:venera_next/features/comic_source/source_installations_scope.dart';
import 'package:venera_next/features/comic_source/source_repositories.dart';
import 'package:venera_next/features/comic_source/source_script_editor.dart';
import 'package:venera_next/features/comic_source/source_script_files.dart';
import 'package:venera_next/features/comic_source/source_script_session.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/selection_operation.dart';

import '../../support/source_data_files.dart';
import 'source_script_editor_test.dart' show waitForEditor;

String script(String version, {String init = '', bool search = false}) =>
    '''
class EditingSource extends ComicSource {
  key = 'editing'; name = 'Editing source'; version = '$version';
  minAppVersion = '1.0.0';
  comic = {loadInfo: async () => ({title:'Book',cover:'',tags:{}}), loadEp: async () => []};
  ${search ? 'search = {load: async () => ({comics: []})};' : ''}
  async init() { $init }
}
''';

class _ScriptFiles extends SourceScriptFiles {
  Future<void> Function(String)? beforeRead, beforeOpen;
  final drafts = <String>[];
  final opened = <String>[];
  final reads = <String>[];

  @override
  Future<String> createDraft({
    required String sourcePath,
    required String cachePath,
  }) async {
    final path = await super.createDraft(
      sourcePath: sourcePath,
      cachePath: cachePath,
    );
    drafts.add(path);
    return path;
  }

  @override
  Future<void> openEditor(String path) async {
    opened.add(path);
    await beforeOpen?.call(path);
  }

  @override
  Future<String> read(String path) async {
    await beforeRead?.call(path);
    final value = await super.read(path);
    reads.add(path);
    return value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late JsEngine engine;
  late ComicSourceManager manager;
  late SourceInstallations queue;
  late ComicSource source;
  late ControlledSourceDataFiles dataFiles;
  late SelectionTaskRegistry tasks;
  late GlobalKey<NavigatorState> navigator;

  Future<void> prepare(WidgetTester tester) async {
    rootBundle.clear();
    tasks = SelectionTaskRegistry();
    navigator = GlobalKey<NavigatorState>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (_) async => false,
    );
    await tester.runAsync(() async {
      if (Platform.isWindows) {
        final native = Directory(
          'build/windows/x64/runner/Release',
        ).absolute.path;
        DynamicLibrary.open('$native/flutter_windows.dll');
        DynamicLibrary.open('$native/flutter_qjs_plugin.dll');
      }
      root = Directory.systemTemp.createTempSync('source-editor-owner-');
      Directory('${root.path}/comic_source').createSync();
      App.dataPath = root.path;
      // Desktop preparation fails before Process.run, so tests never launch
      // an external editor. The production built-in fallback remains intact.
      App.cachePath = '${root.path}/unavailable-cache';
      File(App.cachePath).writeAsStringSync('cache unavailable');
      App.version = '9.0.0';
      App.isInitialized = false;
      Log.isMuted = true;
      await appdata.init();
      await appdata.updateSettings(
        (draft) => draft['language'] = 'en-US',
        sync: false,
      );
      JsEngine.cacheJsInit(await File('assets/init.js').readAsBytes());
      engine = JsEngine();
      await engine.init();
      dataFiles = ControlledSourceDataFiles();
      manager = ComicSourceManager(
        dataStorage: SourceDataStorage(files: dataFiles),
      );
      source = await manager.installScript(
        js: script('1.0.0'),
        fileName: 'editing.js',
        origin: const SourceOrigin(kind: 'file'),
        beforeInstall: () {},
      );
      queue = SourceInstallations(
        manager: manager,
        repositories: SourceRepositories.instance,
        createClient: Dio.new,
      );
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      var references = -1;
      await drain(tester, () async {
        dataFiles.beforeWrite = null;
        dataFiles.beforeReplace = null;
        configureComicSourceDataSavedHandler(null);
        await tasks.closeAndWait();
        await queue.closeAndWait();
        await manager.closeAndWait();
        // Close any manager incorrectly created by the original page, through
        // its public lifetime rather than resetting the production singleton.
        await ComicSourceManager.current?.closeAndWait();
        references = engine.debugOwnedReferenceCount;
        await engine.closeAndWait();
        await appdata.saveData(false);
      });
      expect(references, 0);
      await tester.runAsync(() async {
        await root.delete(recursive: true);
      });
      Log.isMuted = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        null,
      );
    });
  }

  Future<void> show(
    WidgetTester tester, {
    SourceScriptFiles scriptFiles = const SourceScriptFiles(),
    bool window = false,
    VoidCallback? onExit,
  }) => tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      builder: (_, child) {
        Widget content = SelectionTasksScope(
          registry: tasks,
          child: SourceInstallationsScope(queue: queue, child: child!),
        );
        if (window) content = WindowFrame(content, onExit: onExit);
        return content;
      },
      home: ComicSourcePage(scriptFiles: scriptFiles),
    ),
  );

  Future<void> openEditor(WidgetTester tester) async {
    await show(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Source actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit script'));
    await pumpUntil(
      tester,
      () => find.byType(SourceScriptEditor).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    await waitForEditor(tester);
  }

  Future<void> save(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.tap(find.text('Save and reload'));
    await tester.pump();
    await pumpUntil(
      tester,
      () => find.text('Save and reload').evaluate().isNotEmpty,
    );
  }

  Future<void> external(WidgetTester tester, _ScriptFiles files) async {
    App.cachePath = '${root.path}/cache';
    await show(tester, scriptFiles: files);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Source actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit script'));
    await pumpUntil(
      tester,
      () => find.byType(SourceScriptReloadDialog).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
  }

  SourceScriptSession session() => SourceScriptSession(
    source: source,
    replace: (target, text) =>
        manager.replaceScript(target, text, validate: () {}),
  );

  testWidgets('the production editor can save twice in one session', (
    tester,
  ) async {
    await prepare(tester);
    await openEditor(tester);
    await save(tester, script('2.0.0'));
    expect(manager.find('editing')!.version, '2.0.0');
    await save(tester, script('3.0.0'));
    expect(manager.find('editing')!.version, '3.0.0');
    expect(File(source.filePath).readAsStringSync(), script('3.0.0'));
    expect(find.text('Source reloaded'), findsOneWidget);
  });

  testWidgets('unmount after source shutdown does not recreate the manager', (
    tester,
  ) async {
    await prepare(tester);
    await show(tester);
    await tester.pumpAndSettle();
    await tester.runAsync(manager.closeAndWait);
    expect(ComicSourceManager.current, isNull);
    await tester.pumpWidget(const SizedBox());
    expect(ComicSourceManager.current, isNull);
  });

  testWidgets('mounting a page without a live runtime does not create one', (
    tester,
  ) async {
    await prepare(tester);
    await tester.runAsync(manager.closeAndWait);
    await show(tester);
    await tester.pumpAndSettle();
    expect(ComicSourceManager.current, isNull);
    expect(find.text('No installed sources'), findsOneWidget);
  });

  testWidgets('an open editor never saves through a newly assembled manager', (
    tester,
  ) async {
    await prepare(tester);
    await openEditor(tester);
    await tester.runAsync(manager.closeAndWait);
    await save(tester, script('2.0.0'));
    expect(ComicSourceManager.current, isNull);
    expect(File(source.filePath).readAsStringSync(), script('1.0.0'));
    expect(find.text('Source reloaded'), findsNothing);
  });

  testWidgets('a rolled back production save can retry the edited draft', (
    tester,
  ) async {
    await prepare(tester);
    await openEditor(tester);
    await save(
      tester,
      script('2.0.0', init: "throw new Error('editing init failed');"),
    );
    expect(manager.find('editing'), same(source));
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).data,
      contains('editing init failed'),
    );
    expect(
      tester
          .widget<SourceScriptEditor>(find.byType(SourceScriptEditor))
          .canSave!(),
      isTrue,
    );
    await save(tester, script('3.0.0'));
    expect(manager.find('editing')!.version, '3.0.0');
  });

  testWidgets(
    'text edited during saving stays dirty after the saved snapshot completes',
    (tester) async {
      await prepare(tester);
      await openEditor(tester);
      final entered = Completer<void>(), release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      dataFiles.beforeReplace = (_, _) async {
        entered.complete();
        await release.future;
      };
      await tester.enterText(find.byType(TextField), script('2.0.0'));
      await tester.tap(find.text('Save and reload'));
      await pumpUntil(tester, () => entered.isCompleted);
      await tester.enterText(find.byType(TextField), script('3.0.0'));
      dataFiles.beforeReplace = null;
      release.complete();
      await pumpUntil(
        tester,
        () => find.text('Source reloaded').evaluate().isNotEmpty,
      );
      expect(manager.find('editing')!.version, '2.0.0');
      final pop = find.descendant(
        of: find.byType(SourceScriptEditor),
        matching: find.byWidgetPredicate((widget) => widget is PopScope),
      );
      expect(tester.widget<PopScope>(pop).canPop, isFalse);
      await save(tester, script('3.0.0'));
      expect(manager.find('editing')!.version, '3.0.0');
      expect(tester.widget<PopScope>(pop).canPop, isTrue);
    },
  );

  testWidgets(
    'an editor does not adopt an unrelated replacement with the same key',
    (tester) async {
      await prepare(tester);
      await openEditor(tester);
      await tester.runAsync(
        () => manager.replaceScript(source, script('8.0.0'), validate: () {}),
      );
      final unrelated = manager.find('editing');
      await save(tester, script('2.0.0'));
      expect(manager.find('editing'), same(unrelated));
      expect(File(source.filePath).readAsStringSync(), script('8.0.0'));
      expect(find.text('Source reloaded'), findsNothing);
    },
  );

  testWidgets(
    'a replacement receipt keeps its identity when a later mutation finishes first',
    (tester) async {
      await prepare(tester);
      await tester.runAsync(() async {
        ComicSource? owned;
        final editing = SourceScriptSession(
          source: source,
          replace: (target, text) async {
            final result = await manager.replaceScript(
              target,
              text,
              validate: () {},
            );
            owned = result;
            await manager.replaceScript(
              result,
              script('8.0.0'),
              validate: () {},
            );
            return result;
          },
        );
        await editing.save(script('2.0.0'));
        expect(owned!.version, '2.0.0');
        expect(manager.find('editing')!.version, '8.0.0');
        await expectLater(editing.save(script('3.0.0')), throwsA(anything));
        expect(File(source.filePath).readAsStringSync(), script('8.0.0'));
      });
    },
  );

  testWidgets(
    'an applied save failure keeps its diagnosis and disables replay',
    (tester) async {
      await prepare(tester);
      await openEditor(tester);
      final publishFailure = StateError('editor publication failed');
      configureComicSourceDataSavedHandler(() async => throw publishFailure);
      await save(
        tester,
        script(
          '2.0.0',
          init: 'globalThis.editRuns = (globalThis.editRuns || 0) + 1;',
        ),
      );
      final editor = tester.widget<SourceScriptEditor>(
        find.byType(SourceScriptEditor),
      );
      expect(editor.canSave!(), isFalse);
      final button = find.widgetWithText(TextButton, 'Save and reload');
      expect(tester.widget<TextButton>(button).onPressed, isNull);
      expect(
        find.textContaining('Copy your edits before closing.'),
        findsOneWidget,
      );
      expect(manager.find('editing')!.version, '2.0.0');
      configureComicSourceDataSavedHandler(null);
      await tester.runAsync(() async {
        SourceMutationFailure? failure;
        try {
          await editor.onSave(script('3.0.0'));
        } on SourceMutationFailure catch (error) {
          failure = error;
        }
        expect(failure!.state, SourceMutationState.applied);
        expect(
          (failure.cause as SourceMutationFailure).cause,
          same(publishFailure),
        );
        expect(failure.stackTrace.toString(), isNotEmpty);
        expect(Directory(failure.recoveryPath!).existsSync(), isTrue);
        await expectLater(
          editor.onSave(script('3.0.0')),
          throwsA(same(failure)),
        );
        expect(engine.runCode('editRuns'), 1);
        expect(manager.find('editing')!.version, '2.0.0');
      });
    },
  );

  testWidgets(
    'a failed durable commit decision is not mistaken for a retryable save',
    (tester) async {
      await prepare(tester);
      await tester.runAsync(() async {
        final editing = session();
        dataFiles.beforeReplace = (_, _) async {
          final db = sqlite3.open(
            '${root.path}/.source-transactions/transactions.sqlite',
          );
          try {
            db.execute(
              '''CREATE TRIGGER reject_editor_commit BEFORE INSERT ON mutations
            WHEN json_extract(NEW.payload, '\$.phase') = 'committed'
            BEGIN SELECT RAISE(ABORT, 'editor commit denied'); END;''',
            );
          } finally {
            db.dispose();
          }
        };
        SourceMutationFailure? failure;
        try {
          await editing.save(
            script(
              '2.0.0',
              init: 'globalThis.editRuns = (globalThis.editRuns || 0) + 1;',
            ),
          );
        } on SourceMutationFailure catch (error) {
          failure = error;
        }
        dataFiles.beforeReplace = null;
        final db = sqlite3.open(
          '${root.path}/.source-transactions/transactions.sqlite',
        );
        try {
          expect(
            db
                .select(
                  "SELECT json_extract(payload, '\$.phase') AS phase FROM mutations",
                )
                .single['phase'],
            isNot('committed'),
          );
          db.execute('DROP TRIGGER reject_editor_commit');
        } finally {
          db.dispose();
        }
        expect(failure!.state, SourceMutationState.applied);
        expect(
          failure.failures.map((e) => e.stage),
          contains('persist source commit decision'),
        );
        expect(editing.canSave, isFalse);
        await expectLater(
          editing.save(script('3.0.0')),
          throwsA(same(failure)),
        );
        expect(engine.runCode('editRuns'), 1);
        expect(manager.find('editing')!.version, '2.0.0');
        expect(
          () => manager
              .find('editing')!
              .editDataSync((draft) => draft['unsafe'] = true),
          throwsStateError,
        );
      });
    },
  );

  testWidgets(
    'incomplete rollback preserves an external edit and stops further saves',
    (tester) async {
      await prepare(tester);
      await tester.runAsync(() async {
        final editing = session();
        dataFiles.beforeReplace = (_, _) =>
            throw const FileSystemException('editor write denied');
        var changed = false;
        void changeFile() {
          if (!changed &&
              (appdata.settings['searchSources'] as List).contains('editing')) {
            changed = true;
            File(source.filePath).writeAsStringSync('// independent file edit');
          }
        }

        appdata.settings.addListener(changeFile);
        SourceMutationFailure? failure;
        try {
          await editing.save(script('2.0.0', search: true));
        } on SourceMutationFailure catch (error) {
          failure = error;
        } finally {
          appdata.settings.removeListener(changeFile);
          dataFiles.beforeReplace = null;
        }
        expect(failure!.state, SourceMutationState.recoveryRequired);
        expect(
          failure.failures.map((e) => e.stage),
          contains('restore source script'),
        );
        expect(editing.canSave, isFalse);
        await expectLater(
          editing.save(script('3.0.0')),
          throwsA(same(failure)),
        );
        expect(
          File(source.filePath).readAsStringSync(),
          '// independent file edit',
        );
        expect(
          File('${failure.recoveryPath}/original.js').readAsStringSync(),
          script('1.0.0'),
        );
      });
    },
  );

  testWidgets(
    'queued editor saves validate the original data directory before initialization',
    (tester) async {
      await prepare(tester);
      await openEditor(tester);
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final exclusive = AppDataOperations.instance.run(() => release.future);
      await tester.enterText(
        find.byType(TextField),
        script('2.0.0', init: 'globalThis.wrongDirectoryInit = true;'),
      );
      await tester.tap(find.text('Save and reload'));
      await tester.pump();
      App.dataPath = '${root.path}/different-data';
      release.complete();
      await exclusive;
      await pumpUntil(
        tester,
        () => find.text('Save and reload').evaluate().isNotEmpty,
      );
      App.dataPath = root.path;
      expect(engine.runCode('typeof wrongDirectoryInit'), 'undefined');
      expect(manager.find('editing'), same(source));
      expect(File(source.filePath).readAsStringSync(), script('1.0.0'));
    },
  );

  testWidgets(
    'external reloads share one editing session and reopening keeps separate drafts',
    (tester) async {
      await prepare(tester);
      final files = _ScriptFiles();
      await external(tester, files);
      final draft = files.drafts.single;
      for (final version in ['2.0.0', '3.0.0']) {
        File(draft).writeAsStringSync(script(version));
        await tester.tap(find.text('Reload'));
        await tester.pump();
        await pumpUntil(
          tester,
          () => find.text('Source reloaded').evaluate().isNotEmpty,
        );
        expect(manager.find('editing')!.version, version);
      }
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(File(draft).readAsStringSync(), script('3.0.0'));
      await tester.tap(find.byTooltip('Source actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit script'));
      await pumpUntil(tester, () => files.opened.length == 2);
      await tester.pumpAndSettle();
      expect(files.drafts.toSet(), hasLength(2));
      expect(File(files.drafts.last).readAsStringSync(), script('3.0.0'));
      File(files.drafts.last).writeAsStringSync('new independent draft');
      expect(File(draft).readAsStringSync(), script('3.0.0'));
    },
  );

  testWidgets(
    'an external draft read failure can retry without replacing the installed script',
    (tester) async {
      await prepare(tester);
      final files = _ScriptFiles();
      await external(tester, files);
      File(files.drafts.single).writeAsStringSync(script('2.0.0'));
      files.beforeRead = (_) async =>
          throw const FileSystemException('draft temporarily unavailable');
      await tester.tap(find.text('Reload'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('draft temporarily unavailable'),
        findsOneWidget,
      );
      expect(manager.find('editing'), same(source));
      files.beforeRead = null;
      await tester.tap(find.text('Reload'));
      await tester.pump();
      await pumpUntil(
        tester,
        () => find.text('Source reloaded').evaluate().isNotEmpty,
      );
      expect(manager.find('editing')!.version, '2.0.0');
    },
  );

  testWidgets(
    'external reload stops if a newer route covers its pending draft read',
    (tester) async {
      await prepare(tester);
      final files = _ScriptFiles();
      await external(tester, files);
      final entered = Completer<void>(), release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      files.beforeRead = (_) async {
        entered.complete();
        await release.future;
      };
      File(files.drafts.single).writeAsStringSync(script('2.0.0'));
      await tester.tap(find.text('Reload'));
      await pumpUntil(tester, () => entered.isCompleted);
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Newer source page')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      release.complete();
      await pumpUntil(
        tester,
        () => find.text('Reload', skipOffstage: false).evaluate().isNotEmpty,
      );
      expect(find.text('Newer source page'), findsOneWidget);
      expect(manager.find('editing'), same(source));
      expect(File(source.filePath).readAsStringSync(), script('1.0.0'));
    },
  );

  testWidgets(
    'application shutdown joins an external editor launch and suppresses late dialogs',
    (tester) async {
      await prepare(tester);
      App.cachePath = '${root.path}/cache';
      final entered = Completer<void>(), release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final files = _ScriptFiles()
        ..beforeOpen = (_) async {
          entered.complete();
          await release.future;
        };
      await show(tester, scriptFiles: files);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Source actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit script'));
      await pumpUntil(tester, () => entered.isCompleted);
      var closed = false;
      final closing = tasks.closeAndWait().then((_) => closed = true);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(closed, isFalse);
      release.complete();
      await pumpUntil(tester, () => closed);
      await closing;
      expect(find.byType(SourceScriptReloadDialog), findsNothing);
      expect(find.byType(SourceScriptEditor), findsNothing);
      expect(File(files.drafts.single).existsSync(), isTrue);
      expect(ComicSourceManager.current, same(manager));
    },
  );

  testWidgets('a late built-in preparation does not open above a newer route', (
    tester,
  ) async {
    await prepare(tester);
    final entered = Completer<void>(), release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final files = _ScriptFiles()
      ..beforeRead = (_) async {
        entered.complete();
        await release.future;
      };
    await show(tester, scriptFiles: files);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Source actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit script'));
    await pumpUntil(tester, () => entered.isCompleted);
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Newer source page')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    release.complete();
    await pumpUntil(tester, () => files.reads.isNotEmpty);
    await tester.pumpAndSettle();
    expect(find.text('Newer source page'), findsOneWidget);
    expect(find.byType(SourceScriptEditor, skipOffstage: false), findsNothing);
    expect(files.opened, isEmpty);
  });

  testWidgets(
    'the source page follows its explicit queue owner across replacement',
    (tester) async {
      await prepare(tester);
      await show(tester);
      await tester.pumpAndSettle();
      final previousQueue = queue;
      addTearDown(() => drain(tester, previousQueue.closeAndWait));
      await tester.runAsync(() async {
        await manager.closeAndWait();
        manager = ComicSourceManager();
        source = await manager.installScript(
          js: script('9.0.0'),
          fileName: 'replacement.js',
          origin: const SourceOrigin(kind: 'file'),
          beforeInstall: () {},
        );
      });
      await show(tester);
      await tester.pumpAndSettle();
      expect(find.text('No installed sources'), findsOneWidget);
      expect(find.text('9.0.0'), findsNothing);
      queue = SourceInstallations(
        manager: manager,
        repositories: SourceRepositories.instance,
        createClient: Dio.new,
      );
      await show(tester);
      await tester.pumpAndSettle();
      expect(find.text('9.0.0'), findsOneWidget);
      await tester.runAsync(
        () => manager.replaceScript(source, script('10.0.0'), validate: () {}),
      );
      await tester.pumpAndSettle();
      expect(find.text('10.0.0'), findsOneWidget);
      expect(find.text('9.0.0'), findsNothing);
    },
  );

  testWidgets(
    'a session rejects concurrent saves without queuing a second mutation',
    (tester) async {
      await prepare(tester);
      await tester.runAsync(() async {
        final editing = session();
        final first = editing.save(script('2.0.0'));
        await expectLater(editing.save(script('3.0.0')), throwsStateError);
        await first;
        expect(File(source.filePath).readAsStringSync(), script('2.0.0'));
        await editing.save(script('4.0.0'));
        expect(File(source.filePath).readAsStringSync(), script('4.0.0'));
      });
    },
  );

  for (final window in [false, true]) {
    testWidgets(
      'accepted editor save is joined by its original ${window ? 'window' : 'application'}',
      (tester) async {
        await prepare(tester);
        var exits = 0;
        await show(tester, window: window, onExit: () => exits++);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Source actions'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Edit script'));
        await pumpUntil(
          tester,
          () => find.byType(SourceScriptEditor).evaluate().isNotEmpty,
        );
        await tester.pumpAndSettle();
        await waitForEditor(tester);
        final entered = Completer<void>(), release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        dataFiles.beforeReplace = (_, _) async {
          entered.complete();
          await release.future;
        };
        await tester.enterText(find.byType(TextField), script('2.0.0'));
        await tester.tap(find.text('Save and reload'));
        await pumpUntil(tester, () => entered.isCompleted);
        var closed = false;
        Future<void>? closing;
        if (window) {
          (tester.state(find.byType(WindowFrame)) as WindowListener)
              .onWindowClose();
        } else {
          closing = tasks.closeAndWait().then((_) => closed = true);
          await tester.pumpWidget(const SizedBox());
        }
        await tester.pump();
        expect(closed, isFalse);
        expect(exits, 0);
        dataFiles.beforeReplace = null;
        release.complete();
        await pumpUntil(tester, () => window ? exits == 1 : closed);
        if (closing != null) await closing;
        expect(manager.find('editing')!.version, '2.0.0');
        expect(File(source.filePath).readAsStringSync(), script('2.0.0'));
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Future<void> drain(WidgetTester tester, Future<void> Function() action) async {
  var done = false;
  Object? failure;
  StackTrace? failureStack;
  final result = action().then<void>(
    (_) => done = true,
    onError: (Object error, StackTrace stack) {
      failure = error;
      failureStack = stack;
      done = true;
    },
  );
  await pumpUntil(tester, () => done);
  await result;
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
}

Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 500; i++) {
    if (done()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  fail('Source editor operation did not settle.');
}
