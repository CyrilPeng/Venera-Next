import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source_manager.dart';
import 'package:venera_next/features/comic_source/comic_source_summary.dart';
import 'package:venera_next/features/comic_source/source.dart';
import 'package:venera_next/foundation/appdata.dart';

class _Source extends Fake implements ComicSource {
  _Source(this.name);
  @override
  final String name;
  @override
  String get key => name;
  @override
  String get version => '1.0.0';
}

class _Manager extends ChangeNotifier implements ComicSourceManager {
  _Manager(String name) : sources = [_Source(name)];
  final List<ComicSource> sources;
  final updates = <String, String>{};
  bool get observed => hasListeners;
  @override
  bool get isClosing => false;
  @override
  List<ComicSource> all() => List.of(sources);
  @override
  Map<String, String> get availableUpdates => Map.of(updates);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() {
    final language = appdata.settings['language'];
    appdata.settings['language'] = 'en-US';
    addTearDown(() => appdata.settings['language'] = language);
  });
  for (final remove in [false, true]) {
    testWidgets(
      'source summary cannot recreate a closed manager: remove=$remove',
      (tester) async {
        final manager = ComicSourceManager();
        Widget app(Brightness brightness) => MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Scaffold(
            body: CustomScrollView(
              slivers: [ComicSourceSummary(manager: manager)],
            ),
          ),
        );
        try {
          await tester.pumpWidget(app(Brightness.light));
          await manager.closeAndWait();
          expect(ComicSourceManager.current, isNull);
          await tester.pumpWidget(
            remove ? const SizedBox() : app(Brightness.dark),
          );
          await tester.pumpAndSettle();
          expect(ComicSourceManager.current, isNull);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await manager.closeAndWait();
          await ComicSourceManager.current?.closeAndWait();
        }
      },
    );
  }
  testWidgets(
    'source summary replaces borrowed listeners and reads the same owner',
    (tester) async {
      final first = _Manager('First');
      final second = _Manager('Second');
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      Widget app(ComicSourceManager? manager) => MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [ComicSourceSummary(manager: manager)],
          ),
        ),
      );
      await tester.pumpWidget(app(first));
      expect(first.observed, isTrue);
      expect(find.text('First'), findsOneWidget);
      await tester.pumpWidget(app(second));
      expect(first.observed, isFalse);
      expect(second.observed, isTrue);
      expect(find.text('First'), findsNothing);
      expect(find.text('Second'), findsOneWidget);
      first.updates['First'] = '2.0.0';
      first.notifyListeners();
      second.updates['Second'] = '2.0.0';
      second.notifyListeners();
      await tester.pump();
      expect(find.text('1 updates'), findsOneWidget);
      await tester.pumpWidget(app(null));
      expect(second.observed, isFalse);
      expect(find.text('Second'), findsNothing);
      second.notifyListeners();
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('an absent source owner never assembles a replacement manager', (
    tester,
  ) async {
    expect(ComicSourceManager.current, isNull);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: CustomScrollView(slivers: [ComicSourceSummary(manager: null)]),
        ),
      ),
    );
    expect(ComicSourceManager.current, isNull);
    expect(find.text('0'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
