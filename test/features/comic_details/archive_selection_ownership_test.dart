import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/comic_details/archive_download_dialog.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/network/request_scope.dart';
import 'package:window_manager/window_manager.dart';

ArchiveInfo option([String id = 'original']) => ArchiveInfo.fromJson({
  'id': id,
  'title': 'Archive $id',
  'description': 'Synthetic choice',
});

Future<void> frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> drainArchiveWork(
  WidgetTester tester,
  Future<void> Function() action,
) async {
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
  for (var i = 0; i < 200 && !done; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expectSync(done, isTrue, reason: 'The original archive work did not settle.');
  await result;
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
}

class _Input {
  const _Input(this.downloader, this.comicId);
  final ArchiveDownloader downloader;
  final String comicId;
}

class _Host {
  _Host(ArchiveDownloader downloader)
    : input = ValueNotifier(_Input(downloader, 'original-book'));
  final navigator = GlobalKey<NavigatorState>();
  final ValueNotifier<_Input> input;
  final registries = <SelectionTaskRegistry>[];
  SelectionTaskRegistry registry = SelectionTaskRegistry();
  bool allowed = true;
  int exits = 0;
  bool withWindow = false;
  bool expanded = false;
  late MaterialPageRoute<ArchiveDownloadSelection> route;
  late Future<ArchiveDownloadSelection?> result;

  Widget tree() => MaterialApp(
    navigatorKey: navigator,
    builder: (_, child) => SelectionTasksScope(
      registry: registry,
      child: NavigationAdmission(
        allowsNavigation: () => allowed,
        child: withWindow ? WindowFrame(child!, onExit: () => exits++) : child!,
      ),
    ),
    home: const Scaffold(body: Text('Home')),
  );

  Future<void> mount(WidgetTester tester, {bool window = false}) async {
    withWindow = window;
    registries.add(registry);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
      for (final original in registries) {
        await drainArchiveWork(tester, original.closeAndWait);
      }
      input.dispose();
    });
    await tester.pumpWidget(tree());
    route = MaterialPageRoute<ArchiveDownloadSelection>(
      builder: (_) => ValueListenableBuilder<_Input>(
        valueListenable: input,
        builder: (_, value, _) => ArchiveDownloadDialog(
          downloader: value.downloader,
          comicId: value.comicId,
        ),
      ),
    );
    result = navigator.currentState!.push(route);
    await frames(tester);
  }

  Future<void> replaceRegistry(WidgetTester tester) async {
    registry = SelectionTaskRegistry();
    registries.add(registry);
    await tester.pumpWidget(tree());
    await frames(tester);
  }

  Future<void> expand(WidgetTester tester) async {
    if (expanded) {
      tester
          .widget<ExpansionTile>(find.byType(ExpansionTile))
          .onExpansionChanged!(true);
    } else {
      await tester.tap(find.text('Archive').first);
      expanded = true;
    }
    await frames(tester);
  }

  Future<void> chooseArchive(WidgetTester tester) async {
    await expand(tester);
    tester.widget<RadioGroup<int>>(find.byType(RadioGroup<int>)).onChanged(0);
    await frames(tester);
  }

  VoidCallback confirm(WidgetTester tester) => tester
      .widgetList<Button>(find.byType(Button))
      .firstWhere((button) => button.type == ButtonType.filled)
      .onPressed;
}

void main() {
  const windowChannel = MethodChannel('window_manager');
  final messages = <String>[];
  setUp(() {
    rootBundle.clear();
    final language = appdata.settings['language'];
    final muted = Log.isMuted;
    appdata.settings['language'] = 'en-US';
    Log.isMuted = true;
    messages.clear();
    registerShowMessageHandler((_, message) => messages.add(message));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, (_) async => false);
    addTearDown(() {
      appdata.settings['language'] = language;
      Log.isMuted = muted;
      registerShowMessageHandler((_, _) {});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(windowChannel, null);
    });
  });

  for (final failed in [false, true]) {
    testWidgets('covered link completion preserves the newer route: $failed', (
      tester,
    ) async {
      final pending = Completer<Res<String>>();
      var calls = 0;
      final host = _Host(
        ArchiveDownloader((_) async => Res([option()]), (_, _) {
          calls++;
          return pending.future;
        }),
      );
      await host.mount(tester);
      addTearDown(() {
        if (!pending.isCompleted) pending.complete(const Res('synthetic-link'));
      });
      await host.chooseArchive(tester);
      host.confirm(tester)();
      await frames(tester);
      final newer = MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Newer page')),
      );
      host.navigator.currentState!.push(newer);
      await frames(tester);
      expect(
        find.byType(ArchiveDownloadDialog, skipOffstage: false),
        findsOneWidget,
      );
      if (failed) {
        pending.completeError(StateError('original link failure'));
      } else {
        pending.complete(const Res('  synthetic-link  '));
      }
      await frames(tester);
      expect(newer.isCurrent, isTrue);
      expect(messages, isEmpty);
      expect(tester.takeException(), isNull);
      if (!failed) {
        host.navigator.currentState!.pop();
        await frames(tester);
        host.confirm(tester)();
        await frames(tester);
        expect((await host.result)!.url, 'synthetic-link');
        expect(calls, 1);
      }
    });
  }

  for (final inactive in ['frozen', 'covered', 'replaced', 'closed']) {
    testWidgets(
      'retained archive controls reject an inactive host: $inactive',
      (tester) async {
        var reads = 0;
        final host = _Host(
          ArchiveDownloader((_) async {
            reads++;
            return Res([option()]);
          }, (_, _) async => const Res('synthetic-link')),
        );
        await host.mount(tester);
        final confirm = host.confirm(tester);
        final expand = tester
            .widget<ExpansionTile>(find.byType(ExpansionTile))
            .onExpansionChanged!;
        final select = tester
            .widget<RadioGroup<int>>(find.byType(RadioGroup<int>))
            .onChanged;
        if (inactive == 'frozen') {
          host.allowed = false;
        } else if (inactive == 'covered') {
          host.navigator.currentState!.push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Newer page')),
            ),
          );
          await frames(tester);
        } else if (inactive == 'replaced') {
          await host.replaceRegistry(tester);
        } else {
          await drainArchiveWork(tester, host.registry.closeAndWait);
        }
        expand(true);
        select(0);
        confirm();
        await frames(tester);
        expect(reads, 0);
        expect(host.route.isActive, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final link in [false, true]) {
    for (final replacement in [false, true]) {
      testWidgets(
        'original application waits the accepted ${link ? 'link' : 'list'} after ${replacement ? 'replacement' : 'removal'}',
        (tester) async {
          final list = Completer<Res<List<ArchiveInfo>>>();
          final url = Completer<Res<String>>();
          RequestScope? acceptedScope;
          final host = _Host(
            ArchiveDownloader(
              (_) {
                if (link) return Future.value(Res([option()]));
                acceptedScope = RequestScope.current;
                return list.future;
              },
              (_, _) {
                acceptedScope = RequestScope.current;
                return url.future;
              },
            ),
          );
          await host.mount(tester);
          addTearDown(() {
            if (!list.isCompleted) list.complete(Res([option()]));
            if (!url.isCompleted) url.complete(const Res('synthetic-link'));
          });
          if (link) {
            await host.chooseArchive(tester);
            host.confirm(tester)();
          } else {
            await host.expand(tester);
          }
          await frames(tester);
          final original = host.registry;
          if (replacement) {
            await host.replaceRegistry(tester);
          } else {
            await tester.pumpWidget(const SizedBox());
          }
          var closed = false;
          final closing = original.closeAndWait().then((_) => closed = true);
          await frames(tester);
          expect(closed, isFalse);
          expect(acceptedScope, isNotNull);
          expect(acceptedScope!.isCancelled, isTrue);
          if (link) {
            url.completeError(StateError('late synthetic rejection'));
          } else {
            list.complete(Res([option()]));
          }
          await frames(tester);
          await drainArchiveWork(tester, () => closing);
          expect(closed, isTrue);
          expect(messages, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final link in [false, true]) {
    testWidgets('window waits the accepted ${link ? 'link' : 'list'} request', (
      tester,
    ) async {
      final list = Completer<Res<List<ArchiveInfo>>>();
      final url = Completer<Res<String>>();
      final host = _Host(
        ArchiveDownloader(
          (_) => link ? Future.value(Res([option()])) : list.future,
          (_, _) => url.future,
        ),
      );
      await host.mount(tester, window: true);
      addTearDown(() {
        if (!list.isCompleted) list.complete(Res([option()]));
        if (!url.isCompleted) url.complete(const Res('synthetic-link'));
      });
      if (link) {
        await host.chooseArchive(tester);
        host.confirm(tester)();
      } else {
        await host.expand(tester);
      }
      await frames(tester);
      (tester.state(find.byType(WindowFrame)) as WindowListener)
          .onWindowClose();
      await frames(tester);
      expect(host.exits, 0);
      if (link) {
        url.complete(const Res('synthetic-link'));
      } else {
        list.complete(Res([option()]));
      }
      await frames(tester);
      expect(host.exits, 1);
      expect(messages, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'source callback can synchronously close its already registered host',
    (tester) async {
      final pending = Completer<Res<List<ArchiveInfo>>>();
      late _Host host;
      Future<void>? closing;
      var closed = false;
      var calls = 0;
      host = _Host(
        ArchiveDownloader((_) {
          calls++;
          closing = host.registry.closeAndWait().then((_) => closed = true);
          return pending.future;
        }, (_, _) async => const Res('synthetic-link')),
      );
      await host.mount(tester);
      addTearDown(() {
        if (!pending.isCompleted) pending.complete(const Res([]));
      });
      await host.expand(tester);
      expect(calls, 1);
      expect(closed, isFalse);
      pending.complete(const Res([]));
      await drainArchiveWork(tester, () => closing!);
      expect(closed, isTrue);
      expect(calls, 1);
      expect(messages, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'normal selection closes presentation while its accepted list drains',
    (tester) async {
      final pending = Completer<Res<List<ArchiveInfo>>>();
      RequestScope? scope;
      final host = _Host(
        ArchiveDownloader((_) {
          scope = RequestScope.current;
          return pending.future;
        }, (_, _) async => const Res('synthetic-link')),
      );
      await host.mount(tester);
      addTearDown(() {
        if (!pending.isCompleted) pending.complete(const Res([]));
      });
      await host.expand(tester);
      host.confirm(tester)();
      await frames(tester);
      expect(await host.result, isA<ArchiveDownloadSelection>());
      expect(scope!.isCancelled, isTrue);
      var closed = false;
      final closing = host.registry.closeAndWait().then((_) => closed = true);
      await frames(tester);
      expect(closed, isFalse);
      pending.complete(const Res([]));
      await drainArchiveWork(tester, () => closing);
      expect(closed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  for (final link in [false, true]) {
    testWidgets(
      'replacement inputs reject the original ${link ? 'link' : 'list'}',
      (tester) async {
        final list = Completer<Res<List<ArchiveInfo>>>();
        final url = Completer<Res<String>>();
        final host = _Host(
          ArchiveDownloader(
            (_) => link ? Future.value(Res([option()])) : list.future,
            (_, _) => url.future,
          ),
        );
        await host.mount(tester);
        addTearDown(() {
          if (!list.isCompleted) list.complete(Res([option()]));
          if (!url.isCompleted) url.complete(const Res('old-link'));
        });
        if (link) {
          await host.chooseArchive(tester);
          host.confirm(tester)();
        } else {
          await host.expand(tester);
        }
        await frames(tester);
        var newReads = 0;
        host.input.value = _Input(
          ArchiveDownloader((id) async {
            expectSync(id, 'replacement-book');
            newReads++;
            return Res([option('replacement')]);
          }, (_, _) async => const Res('replacement-link')),
          'replacement-book',
        );
        await frames(tester);
        if (link) {
          url.complete(const Res('old-link'));
        } else {
          list.complete(Res([option()]));
        }
        await frames(tester);
        expect(host.route.isCurrent, isTrue);
        expect(
          find.text('Archive original', skipOffstage: false),
          findsNothing,
        );
        expect(
          tester
              .widget<RadioGroup<int>>(find.byType(RadioGroup<int>))
              .groupValue,
          -1,
        );
        await host.expand(tester);
        expect(newReads, 1);
        expect(
          find.text('Archive replacement', skipOffstage: false),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
