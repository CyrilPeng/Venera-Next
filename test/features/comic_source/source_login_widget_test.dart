import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source_manager.dart';
import 'package:venera_next/features/comic_source/comic_source_page.dart';
import 'package:venera_next/features/comic_source/source.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';

class _Source extends Fake implements ComicSource {
  _Source(this.account);
  @override
  Future<void> closeDataWrites() async {}

  @override
  final AccountConfig account;
  @override
  String get key => 'login_test';
  @override
  String get name => 'Login source';
  @override
  String get version => '1.0.0';
  @override
  String get filePath => '';
  @override
  Map<String, dynamic> data = {};
  @override
  bool get isLogged => data['account'] != null;
  int saves = 0;
  Future<void> Function()? save;
  @override
  Future<void> saveData() async {
    saves++;
    await save?.call();
  }

  @override
  JsCallbackScope createSettingsCallbackScope() => JsCallbackScope();
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  final messages = <String>[];
  setUp(() {
    rootBundle.clear();
    messages.clear();
    final language = appdata.settings['language'];
    final muted = Log.isMuted;
    appdata.settings['language'] = 'en-US';
    Log.isMuted = true;
    registerShowMessageHandler((context, message) => messages.add(message));
    addTearDown(() {
      appdata.settings['language'] = language;
      Log.isMuted = muted;
      registerShowMessageHandler((context, message) {});
    });
  });
  Future<void> show(
    WidgetTester tester,
    _Source source, {
    bool login = true,
  }) async {
    ComicSourceManager().add(source);
    addTearDown(() => ComicSourceManager().remove(source.key));
    await tester.pumpWidget(const MaterialApp(home: ComicSourcePage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Show source settings'));
    await tester.pumpAndSettle();
    if (login) {
      await tester.tap(find.text('Log in'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      for (var i = 0; i < fields.evaluate().length; i++) {
        await tester.enterText(fields.at(i), 'value$i');
      }
    }
  }

  for (final cookies in [false, true]) {
    AccountConfig config(Future<Res<bool>> Function() action) => AccountConfig(
      cookies ? null : (_, password) => action(),
      null,
      null,
      () {},
      null,
      null,
      cookies ? ['session'] : null,
      cookies
          ? (_) async {
              final res = await action();
              return !res.error && res.data;
            }
          : null,
    );
    testWidgets(
      'login retries thrown failure and prevents duplicate submission; cookies=$cookies',
      (tester) async {
        var pending = Completer<Res<bool>>();
        var calls = 0;
        final source = _Source(
          config(() {
            calls++;
            return pending.future;
          }),
        );
        await show(tester, source);
        await tester.tap(find.text('Continue'));
        await tester.tap(find.text('Continue'));
        expect(calls, 1);
        pending.completeError(StateError('login failed'));
        await tester.pumpAndSettle();
        expect(messages.single, contains('login failed'));
        expect(find.text('Continue'), findsOneWidget);
        pending = Completer<Res<bool>>();
        await tester.tap(find.text('Continue'));
        expect(calls, 2);
        pending.complete(const Res(true));
        await tester.pumpAndSettle();
        expect(find.text('Continue'), findsNothing);
        if (cookies) expect(source.data['account'], 'ok');
        expect(source.saves, greaterThan(0));
        expect(tester.takeException(), isNull);
      },
    );
    for (final failed in [false, true]) {
      testWidgets(
        'late login completion after unmount; cookies=$cookies failed=$failed',
        (tester) async {
          final pending = Completer<Res<bool>>();
          final source = _Source(config(() => pending.future));
          await show(tester, source);
          await tester.tap(find.text('Continue'));
          await tester.pumpWidget(const SizedBox());
          if (failed) {
            pending.completeError(StateError('late'));
          } else {
            pending.complete(const Res(true));
          }
          await tester.pump();
          expect(messages, isEmpty);
          expect(source.data['account'], isNull);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'cookie login waits for persistence and recovers from save failure',
    (tester) async {
      final saving = Completer<void>();
      final source = _Source(
        AccountConfig(null, null, null, () {}, null, null, [
          'session',
        ], (_) async => true),
      );
      source.save = () => saving.future;
      await show(tester, source);
      await tester.tap(find.text('Continue'));
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget);
      expect(source.saves, 1);
      saving.completeError(StateError('save failed'));
      await tester.pumpAndSettle();
      expect(messages.single, contains('save failed'));
      source.save = null;
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Continue'), findsNothing);
    },
  );

  testWidgets('re-login retries errors and ignores late errors after unmount', (
    tester,
  ) async {
    var pending = Completer<Res<bool>>();
    var calls = 0;
    final source = _Source(
      AccountConfig(
        (_, password) {
          calls++;
          return pending.future;
        },
        null,
        null,
        () {},
        null,
        null,
        null,
        null,
      ),
    )..data['account'] = ['user', 'password'];
    await show(tester, source, login: false);
    await tester.tap(find.text('Re-login'));
    await tester.tap(find.text('Re-login'));
    expect(calls, 1);
    pending.completeError(StateError('retry'));
    await tester.pumpAndSettle();
    expect(messages.single, contains('retry'));
    pending = Completer<Res<bool>>();
    await tester.tap(find.text('Re-login'));
    expect(calls, 2);
    await tester.pumpWidget(const SizedBox());
    messages.clear();
    pending.completeError(StateError('late'));
    await tester.pump();
    expect(messages, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
