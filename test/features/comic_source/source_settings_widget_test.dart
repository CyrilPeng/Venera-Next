import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source_manager.dart';
import 'package:venera_next/features/comic_source/comic_source_page.dart';
import 'package:venera_next/features/comic_source/source.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/js_engine.dart';

class _Callback extends JSInvokable {
  _Callback(this.action);
  final Object? Function() action;
  int destroyed = 0;
  @override
  dynamic invoke(List args, [dynamic thisVal]) => action();
  @override
  void destroy() => destroyed++;
}

class _Source extends Fake implements ComicSource {
  @override
  Future<void> closeDataWrites() async {}

  final root = JsCallbackScope();
  final callbacks = <_Callback>[];
  Object? Function() action = () => null;
  @override
  String get key => 'settings_widget_source';
  @override
  String get name => 'Settings test source';
  @override
  String get version => '1.0.0';
  @override
  String get filePath => '';
  @override
  Map<String, dynamic> data = {};
  @override
  JsCallbackScope createSettingsCallbackScope() => root.fork();
  @override
  Map<String, Map<String, dynamic>>? getSettingsDynamic({
    required JsCallbackScope callbacks,
  }) {
    final raw = _Callback(action);
    this.callbacks.add(raw);
    final retained = callbacks.retain(raw);
    raw.free();
    return {
      'action': {
        'type': 'callback',
        'title': 'Action',
        'buttonText': 'Run action',
        'callback': retained,
      },
    };
  }

  @override
  void disposeRuntimeCallbacks() => root.dispose();
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  late _Source source;
  final messages = <String>[];
  setUp(() {
    rootBundle.clear();
    messages.clear();
    registerShowMessageHandler((context, message) => messages.add(message));
    final muted = Log.isMuted;
    Log.isMuted = true;
    addTearDown(() {
      Log.isMuted = muted;
      registerShowMessageHandler((context, message) {});
    });
    final language = appdata.settings['language'];
    appdata.settings['language'] = 'en-US';
    addTearDown(() => appdata.settings['language'] = language);
    source = _Source();
    ComicSourceManager().add(source);
  });
  tearDown(() => ComicSourceManager().remove(source.key));

  Future<void> show(WidgetTester tester, {bool dark = false}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: dark ? ThemeData.dark() : ThemeData.light(),
        home: const ComicSourcePage(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> expand(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Show source settings'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'settings rebuild, collapse and unmount release only their snapshots',
    (tester) async {
      await show(tester);
      expect(source.callbacks, isEmpty);
      await expand(tester);
      expect(source.callbacks, isNotEmpty);
      final first = source.callbacks.last;
      expect(first.destroyed, 0);
      await show(tester, dark: true);
      expect(first.destroyed, 1);
      final rebuilt = source.callbacks.last;
      expect(rebuilt.destroyed, 0);
      await tester.tap(find.byTooltip('Hide source settings'));
      await tester.pumpAndSettle();
      expect(rebuilt.destroyed, 1);
      await expand(tester);
      final reopened = source.callbacks.last;
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(reopened.destroyed, 1);
      expect(
        source.callbacks.every((callback) => callback.destroyed == 1),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('pending callback may complete after settings unmount', (
    tester,
  ) async {
    final completion = Completer<void>();
    source.action = () => completion.future;
    await show(tester);
    await expand(tester);
    await tester.tap(find.text('Run action'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    completion.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
      source.callbacks.every((callback) => callback.destroyed == 1),
      isTrue,
    );
  });

  for (final asynchronous in [false, true]) {
    testWidgets(
      'callback failure is shown and can retry; async=$asynchronous',
      (tester) async {
        var calls = 0;
        source.action = () {
          calls++;
          if (calls > 1) return null;
          if (asynchronous) {
            return Future<void>.error(StateError('setting failed'));
          }
          throw StateError('setting failed');
        };
        await show(tester);
        await expand(tester);
        await tester.tap(find.text('Run action'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(messages.single, contains('setting failed'));
        await tester.tap(find.text('Run action'));
        await tester.pumpAndSettle();
        expect(calls, 2);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'rapid taps do not duplicate a running callback; late failure is safe',
    (tester) async {
      var calls = 0;
      final completion = Completer<void>();
      source.action = () {
        calls++;
        return completion.future;
      };
      await show(tester);
      await expand(tester);
      await tester.tap(find.text('Run action'));
      await tester.tap(find.text('Run action'));
      expect(calls, 1);
      await tester.pumpWidget(const SizedBox());
      completion.completeError(StateError('late failure'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}
