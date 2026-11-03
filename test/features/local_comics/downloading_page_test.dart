import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/local_comics/download_task.dart';
import 'package:venera_next/features/local_comics/downloading_page.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/comic_type.dart';

void main() {
  setUp(() => LocalManager.current?.dispose());
  tearDown(() => LocalManager.current?.dispose());

  Widget page({Brightness brightness = Brightness.light}) => MaterialApp(
    theme: ThemeData(brightness: brightness),
    home: const DownloadingPage(),
  );

  testWidgets(
    'missing-only queue shows waiting status and explicit retry instead of Start',
    (tester) async {
      final task = _Task('missing')..awaitingMissing = true;
      LocalManager().restorePausedDownloads([task]);
      await tester.pumpWidget(page());
      expect(find.text('Waiting for missing pages'), findsOneWidget);
      expect(find.text('Start'), findsNothing);
      await tester.tap(find.byIcon(Icons.more_horiz).first);
      await tester.pumpAndSettle();
      expect(find.text('Retry missing pages'), findsOneWidget);
      expect(find.text('Read downloaded pages'), findsOneWidget);
      expect(find.text('Remove task and keep local pages'), findsOneWidget);
      expect(task.resumes, 0);
      await tester.pumpWidget(const SizedBox());
      expect(task.listenerCount, 0);
    },
  );

  testWidgets(
    'theme changes do not duplicate subscriptions and unmount removes all',
    (tester) async {
      final task = _Task('a');
      LocalManager().restorePausedDownloads([task]);
      await tester.pumpWidget(page());
      expect(task.listenerCount, 2);
      await tester.pumpWidget(page(brightness: Brightness.dark));
      await tester.pumpAndSettle();
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(task.listenerCount, 2);
      await tester.pumpWidget(const SizedBox());
      expect(task.listenerCount, 0);
      task.emit();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'same-identity replacement retargets page and reused tile listeners',
    (tester) async {
      final manager = LocalManager();
      final original = _Task('same')..label = 'Original';
      manager.restorePausedDownloads([original]);
      await tester.pumpWidget(page());
      expect(original.listenerCount, 2);
      final replacement = _Task('same')..label = 'Replacement';
      expect(original, replacement);
      manager.restorePausedDownloads([replacement]);
      manager.resumeDownload(replacement);
      await tester.pump();
      expect(original.listenerCount, 0);
      expect(replacement.listenerCount, 2);
      replacement.label = 'Updated replacement';
      replacement.emit();
      await tester.pump();
      expect(find.text('Updated replacement'), findsOneWidget);
      expect(find.text('Original'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      expect(replacement.listenerCount, 0);
      original.emit();
      replacement.emit();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('page pause withdraws a start pending old cleanup', (
    tester,
  ) async {
    final manager = LocalManager();
    final gate = Completer<void>();
    final task = _Task('a')..cleanup = gate.future;
    manager.restorePausedDownloads([task]);
    await tester.pumpWidget(page());
    final stopped = manager.pauseDownload(task);
    await tester.pump();
    await tester.tap(find.widgetWithIcon(OutlinedButton, Icons.play_arrow));
    await tester.pump();
    expect(manager.isDownloadResumePending, isTrue);
    expect(task.resumes, 0);
    await tester.tap(find.widgetWithIcon(OutlinedButton, Icons.pause));
    await tester.pump();
    expect(manager.isDownloadResumePending, isFalse);
    gate.complete();
    await tester.pump();
    await stopped;
    await tester.pump();
    expect(task.resumes, 0);
    await tester.tap(find.widgetWithIcon(OutlinedButton, Icons.play_arrow));
    await tester.pump();
    expect(task.resumes, 1);
    await tester.pumpWidget(const SizedBox());
    expect(task.listenerCount, 0);
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'full download error can be opened, scrolled and copied: $brightness',
      (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final text = List.generate(
          40,
          (i) => 'Connection diagnostic line $i',
        ).join('\n');
        final task = _Task('error')
          ..error = true
          ..status = text;
        LocalManager().restorePausedDownloads([task]);
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await tester.pumpWidget(page(brightness: brightness));
        expect(tester.takeException(), isNull, reason: 'download list layout');
        expect(find.text('Error'), findsOneWidget);
        expect(
          find.widgetWithIcon(OutlinedButton, Icons.play_arrow),
          findsOneWidget,
        );
        await tester.tap(find.byIcon(Icons.more_horiz));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'download menu layout');
        await tester.tap(find.text('Error details'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'error dialog layout');
        expect(find.text('Download error'), findsOneWidget);
        expect(
          tester.widget<SelectableText>(find.byType(SelectableText)).data,
          text,
        );
        await tester.tap(find.text('Copy'));
        await tester.pump();
        expect(copied, text);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}

class _Task extends DownloadTask {
  _Task(this.id);
  @override
  final String id;
  final _listeners = <VoidCallback>[];
  int get listenerCount => _listeners.length;
  String label = 'Task';
  bool paused = true;
  bool awaitingMissing = false;
  @override
  bool get isAwaitingMissingPages => awaitingMissing;
  bool error = false;
  String status = 'Downloading';
  int resumes = 0;
  Future<void>? cleanup;

  @override
  void addListener(VoidCallback listener) {
    _listeners.add(listener);
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
    super.removeListener(listener);
  }

  void emit() => notifyListeners();
  @override
  ComicType get comicType => const ComicType(17);
  @override
  String get title => label;
  @override
  String? get cover => null;
  @override
  String get message => status;
  @override
  bool get isPaused => paused;
  @override
  bool get isError => error;
  @override
  int get speed => 0;
  @override
  double get progress => 0;
  @override
  Future<void> get pendingCleanup => cleanup ?? Future.value();
  @override
  void pause() {
    paused = true;
    emit();
  }

  @override
  void resume() {
    paused = false;
    resumes++;
    emit();
  }

  @override
  void cancel() => pause();
  @override
  Map<String, dynamic> toJson() => {'id': id};
  @override
  LocalComic toLocalComic() => throw UnsupportedError('UI fixture');
}
