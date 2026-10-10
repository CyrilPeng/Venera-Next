import 'package:venera_next/features/history/history_scope.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/history/history_page.dart';
import 'package:venera_next/features/history/history_manager.dart';
import 'package:venera_next/features/history/history_model.dart';
import 'package:venera_next/features/comic_widgets/comic_widgets.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';

class _Manager extends HistoryManager {
  _Manager() : super.create();
  Stream<RefreshProgress> Function()? stream;
  Future<bool> Function() single = () async => true;
  Object? readError;
  @override
  List<History> getAll() {
    if (readError != null) throw readError!;
    return [];
  }

  @override
  Stream<RefreshProgress> refreshAllHistoriesStream() =>
      stream?.call() ?? super.refreshAllHistoriesStream();
  @override
  Future<bool> refreshHistoryInfo(
    History history, {
    Future<void> Function(Duration)? retryDelay,
  }) => single();
}

void main() {
  late _Manager manager;
  final messages = <String>[];
  setUp(() {
    final old = _historyOwner;
    final language = appdata.settings['language'];
    final muted = Log.isMuted;
    manager = _Manager();
    _historyOwner = manager;
    messages.clear();
    appdata.settings['language'] = 'en-US';
    Log.isMuted = true;
    registerShowMessageHandler((context, message) => messages.add(message));
    addTearDown(() {
      _historyOwner = old;
      manager.dispose();
      appdata.settings['language'] = language;
      Log.isMuted = muted;
      registerShowMessageHandler((context, message) {});
    });
  });
  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(_libraryView(MaterialApp(home: HistoryPage())));
    await tester.pumpAndSettle();
  }

  void refresh(WidgetTester tester) => tester
      .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.refresh))
      .onPressed!();
  for (final mode in ['success', 'failure', 'cancel', 'unmount']) {
    testWidgets('batch refresh cleanup and deduplication: $mode', (
      tester,
    ) async {
      var calls = 0;
      var cancellations = 0;
      final progress = StreamController<RefreshProgress>(
        onCancel: () {
          cancellations++;
        },
      );
      manager.stream = () {
        calls++;
        return progress.stream;
      };
      await show(tester);
      refresh(tester);
      refresh(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(calls, 1);
      progress.add(RefreshProgress(2, 1, 1, 0, 0));
      await tester.pump();
      if (mode == 'cancel') {
        await tester.tap(find.text('Cancel'));
      } else if (mode == 'unmount') {
        await tester.pumpWidget(const SizedBox());
      } else if (mode == 'failure') {
        progress.addError(StateError('refresh failed'));
      } else {
        progress.add(RefreshProgress(2, 2, 1, 1, 0));
        unawaited(progress.close());
      }
      await tester.pump();
      await tester.runAsync(() async {});
      await tester.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(cancellations, 1);
      if (mode == 'success') {
        expect(messages.single, contains('Success 1, Failed 1'));
      } else if (mode == 'failure') {
        expect(messages.single, contains('refresh failed'));
        manager.stream = () => Stream.value(RefreshProgress(0, 0, 0, 0, 0));
        refresh(tester);
        await tester.pump();
        await tester.runAsync(() async {});
        await tester.pumpAndSettle();
        expect(messages.length, 2);
      } else {
        expect(messages, isEmpty);
      }
      unawaited(progress.close());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('single refresh deduplicates and ignores late failures', (
    tester,
  ) async {
    final pending = Completer<bool>();
    var calls = 0;
    manager.single = () {
      calls++;
      return pending.future;
    };
    await show(tester);
    final item = History(
      type: ComicType.local,
      time: DateTime(2026),
      title: 'Book',
      subtitle: '',
      cover: '',
      ep: 1,
      page: 1,
      id: '1',
      readEpisode: {},
      maxPage: null,
      readDurationMs: 0,
    );
    final action = tester
        .widget<SliverGridComics>(
          find.byType(SliverGridComics, skipOffstage: false),
        )
        .menuBuilder!(item)
        .first
        .onClick;
    action();
    action();
    expect(calls, 1);
    await tester.pumpWidget(const SizedBox());
    pending.completeError(StateError('late'));
    await tester.pump();
    expect(messages, isEmpty);
    expect(tester.takeException(), isNull);
  });
  test('producer forwards setup failure and closes its stream', () async {
    final error = StateError('read failed');
    manager.readError = error;
    await expectLater(
      manager.refreshAllHistoriesStream(),
      emitsInOrder([emitsError(same(error)), emitsDone]),
    );
  });
}

HistoryManager? _historyOwner;
HistoryManager _historyForView() => _historyOwner ??= HistoryManager.create();
Widget _libraryView(Widget child) {
  return HistoryScope(manager: _historyForView(), child: child);
}
