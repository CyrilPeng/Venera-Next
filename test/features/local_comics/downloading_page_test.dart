import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/local_comics/download_task.dart';
import 'package:venera_next/features/local_comics/downloading_page.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/comic_type.dart';

void main() {
  setUp(LocalManager.resetForTesting);
  tearDown(LocalManager.resetForTesting);

  Widget page({Brightness brightness = Brightness.light}) => MaterialApp(
    theme: ThemeData(brightness: brightness),
    home: const DownloadingPage(),
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
}

class _Task extends DownloadTask {
  _Task(this.id);
  @override
  final String id;
  final _listeners = <VoidCallback>[];
  int get listenerCount => _listeners.length;
  String label = 'Task';
  bool paused = true;
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
  String get message => 'Downloading';
  @override
  bool get isPaused => paused;
  @override
  bool get isError => false;
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
