import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_details/rating_dialog.dart';
import 'package:venera_next/features/comic_source/source_script_editor.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/res.dart';
import '../comic_source/source_script_editor_test.dart' show waitForEditor;

class _AfterConfirmation extends NavigatorObserver {
  void Function()? onConfirmed;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) {
      unawaited(
        route.popped.then((value) {
          if (value == true) onConfirmed?.call();
        }),
      );
    }
  }
}

void main() {
  final messages = <String>[];
  setUp(() {
    rootBundle.clear();
    final language = appdata.settings['language'];
    appdata.settings['language'] = 'en-US';
    addTearDown(() => appdata.settings['language'] = language);
    messages.clear();
    registerShowMessageHandler((context, message) => messages.add(message));
    addTearDown(() => registerShowMessageHandler((context, message) {}));
  });
  for (final failed in [false, true]) {
    testWidgets(
      'late rating cannot affect a newer route above its mounted dialog: failed=$failed',
      (tester) async {
        final navigator = GlobalKey<NavigatorState>();
        final pending = Completer<Res<bool>>();
        await tester.pumpWidget(
          MaterialApp(navigatorKey: navigator, home: const Scaffold()),
        );
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => ComicRatingDialog(submit: (_) => pending.future),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Submit'));
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Newer page')),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byType(ComicRatingDialog, skipOffstage: false),
          findsOneWidget,
        );
        if (failed) {
          pending.completeError(StateError('late rating failure'));
        } else {
          pending.complete(const Res(true));
        }
        await tester.pumpAndSettle();
        expect(find.text('Newer page'), findsOneWidget);
        expect(messages, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'rating respects host admission before submit and after completion',
    (tester) async {
      var allowed = false, calls = 0;
      final pending = Completer<Res<bool>>();
      await tester.pumpWidget(
        NavigationAdmission(
          allowsNavigation: () => allowed,
          child: MaterialApp(
            home: Scaffold(
              body: ComicRatingDialog(
                submit: (_) {
                  calls++;
                  return pending.future;
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Submit'));
      await tester.pump();
      expect(calls, 0);
      allowed = true;
      await tester.tap(find.text('Submit'));
      await tester.pump();
      expect(calls, 1);
      allowed = false;
      pending.complete(const Res(true));
      await tester.pumpAndSettle();
      expect(find.byType(ComicRatingDialog), findsOneWidget);
      expect(messages, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a frozen host prevents source save and discard presentation', (
    tester,
  ) async {
    var saves = 0;
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      NavigationAdmission(
        allowsNavigation: () => false,
        child: MaterialApp(navigatorKey: navigator, home: const Scaffold()),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => SourceScriptEditor(
          script: 'original',
          onSave: (_) async => saves++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await waitForEditor(tester);
    await tester.enterText(find.byType(TextField), 'unsaved');
    await tester.tap(find.text('Save and reload'));
    await tester.pump();
    expect(saves, 0);
    await navigator.currentState!.maybePop();
    await tester.pumpAndSettle();
    expect(find.text('Discard changes'), findsNothing);
    expect(find.byType(SourceScriptEditor), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('discard confirmation cannot close a subsequently pushed route', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    final observer = _AfterConfirmation();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [observer],
        home: const Scaffold(),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) =>
            SourceScriptEditor(script: 'original', onSave: (_) async {}),
      ),
    );
    await tester.pumpAndSettle();
    await waitForEditor(tester);
    await tester.enterText(find.byType(TextField), 'unsaved');
    await tester.pump();
    observer.onConfirmed = () {
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Newer page')),
        ),
      );
    };
    await navigator.currentState!.maybePop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard changes'));
    await tester.pumpAndSettle();
    expect(find.text('Newer page'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
