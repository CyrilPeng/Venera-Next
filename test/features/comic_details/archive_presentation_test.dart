import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/comic_details/archive_download_dialog.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/selection_operation.dart';

import 'archive_selection_ownership_test.dart' show drainArchiveWork, frames;

Iterable<Object> _causes(Object error) sync* {
  yield error;
  if (error is SelectionCleanupFailure) {
    if (error.operationError != null) yield* _causes(error.operationError!);
    for (final failure in error.failures) {
      if (failure case (error: final Object cause, stack: final StackTrace _)) {
        yield* _causes(cause);
      } else {
        yield* _causes(failure);
      }
    }
  }
}

void main() {
  late BuildContext context;
  late GlobalKey<NavigatorState> navigator;
  late SelectionTaskRegistry registry;
  var reads = 0;
  final downloader = ArchiveDownloader(
    (_) async => const Res([]),
    (_, _) async => const Res('synthetic-link'),
  );

  setUp(() {
    rootBundle.clear();
    final language = appdata.settings['language'];
    final muted = Log.isMuted;
    appdata.settings['language'] = 'en-US';
    Log.isMuted = true;
    navigator = GlobalKey<NavigatorState>();
    registry = SelectionTaskRegistry();
    reads = 0;
    addTearDown(() {
      appdata.settings['language'] = language;
      Log.isMuted = muted;
    });
  });

  Future<void> host(WidgetTester tester, {bool failing = false}) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, _) => SelectionTasksScope(
          registry: registry,
          child: failing
              ? _FailingNavigator(
                  key: navigator,
                  onGenerateRoute: (_) => MaterialPageRoute<void>(
                    builder: (value) {
                      context = value;
                      return const Scaffold();
                    },
                  ),
                )
              : Navigator(
                  key: navigator,
                  onGenerateRoute: (_) => MaterialPageRoute<void>(
                    builder: (value) {
                      context = value;
                      return const Scaffold();
                    },
                  ),
                ),
        ),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await drainArchiveWork(tester, registry.closeAndWait);
    });
  }

  Future<ArchiveDownloadSelection?> show() => showArchiveDownloadDialog(
    context: context,
    downloader: ArchiveDownloader((id) {
      reads++;
      return downloader.getArchives(id);
    }, downloader.getDownloadUrl),
    comicId: 'original',
  );

  for (final action in ['normal', 'back', 'barrier']) {
    testWidgets('archive presentation keeps the $action result', (
      tester,
    ) async {
      await host(tester);
      final result = show();
      await frames(tester);
      if (action == 'normal') {
        await tester.tap(find.text('Confirm'));
      } else if (action == 'back') {
        navigator.currentState!.pop();
      } else {
        await tester.tapAt(const Offset(1, 1));
      }
      ArchiveDownloadSelection? selected;
      await drainArchiveWork(tester, () async {
        selected = await result;
      });
      if (action == 'normal') {
        expect(selected, isA<ArchiveDownloadSelection>());
        expect(selected!.url, isNull);
      } else {
        expect(selected, isNull);
      }
      expect(reads, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('application closure removes only its original archive route', (
    tester,
  ) async {
    await host(tester);
    final result = show();
    await frames(tester);
    final newer = MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('Newer page')),
    );
    navigator.currentState!.push(newer);
    await frames(tester);
    await drainArchiveWork(tester, registry.closeAndWait);
    expect(await result, isNull);
    expect(newer.isCurrent, isTrue);
    expect(find.text('Newer page'), findsOneWidget);
    expect(reads, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed removal reports and retries the exact original route', (
    tester,
  ) async {
    await host(tester, failing: true);
    final original = navigator.currentState! as _FailingNavigatorState;
    Object? presentationError;
    final result = show().then<void>(
      (_) {},
      onError: (Object error) {
        presentationError = error;
      },
    );
    await frames(tester);
    try {
      Object? closeError;
      await drainArchiveWork(
        tester,
        () => registry.closeAndWait().catchError((Object error) {
          closeError = error;
        }),
      );
      await drainArchiveWork(tester, () => result);
      expect(closeError, isA<SelectionCleanupFailure>());
      expect(_causes(closeError!), contains(same(original.failure)));
      expect(_causes(presentationError!), contains(same(original.failure)));
      expect(original.removals, 1);
      expect(find.byType(ArchiveDownloadDialog), findsOneWidget);
      original.fails = false;
      await drainArchiveWork(tester, registry.closeAndWait);
      await frames(tester);
      expect(original.removals, 2);
      expect(find.byType(ArchiveDownloadDialog), findsNothing);
      expect(reads, 0);
      expect(tester.takeException(), isNull);
    } finally {
      original.fails = false;
    }
  });
}

class _FailingNavigator extends Navigator {
  const _FailingNavigator({super.key, super.onGenerateRoute});
  @override
  NavigatorState createState() => _FailingNavigatorState();
}

class _FailingNavigatorState extends NavigatorState {
  bool fails = true;
  int removals = 0;
  final failure = StateError('archive route removal failed');
  @override
  void removeRoute<T extends Object?>(Route<T> route, [T? result]) {
    removals++;
    if (fails) throw failure;
    super.removeRoute(route, result);
  }
}
