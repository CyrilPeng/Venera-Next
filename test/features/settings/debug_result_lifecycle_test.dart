import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/settings/debug.dart';
import 'package:venera_next/features/settings/debug_evaluator.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';

class _Reference extends JSRef {
  _Reference({this.failure});
  final Object? failure;
  int destroys = 0;
  @override
  void destroy() {
    destroys++;
    if (failure != null) throw failure!;
  }

  @override
  String toString() => 'reference';
}

void main() {
  test(
    'synchronous graph observes an immediately rejected descendant',
    () async {
      final reference = _Reference();
      final rejection = {'reference': reference};
      final task = DebugEvaluator(
        evaluate: (_) => {'pending': Future<Object?>.error(rejection)},
        release: discardJsResult,
        drain: drainJsResultDescendants,
      ).start('object');
      expect(await task.result, contains('pending:'));
      await expectLater(
        task.completion,
        throwsA(isA<DebugEvaluationFailure>()),
      );
      expect(reference.destroys, 1);
    },
  );

  testWidgets('descendants release after a new run and page removal', (
    tester,
  ) async {
    final first = Completer<Object?>();
    final second = Completer<Object?>();
    var response = first;
    final key = GlobalKey<DebugPageState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DebugPage(
            key: key,
            evaluate: (_) => {'pending': response.future},
          ),
        ),
      ),
    );
    await key.currentState!.run();
    expect(key.currentState!.running, isFalse);
    response = second;
    await key.currentState!.run();
    final displayed = key.currentState!.result;
    final oldReference = _Reference();
    first.complete({'late': oldReference});
    await tester.pump();
    expect(oldReference.destroys, 1);
    expect(key.currentState!.result, displayed);
    await tester.pumpWidget(const SizedBox.shrink());
    final detachedReference = _Reference();
    second.complete({'late': detachedReference});
    await tester.pump();
    expect(detachedReference.destroys, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('detached descendant rejection is released and logged', (
    tester,
  ) async {
    final response = Completer<Object?>();
    final key = GlobalKey<DebugPageState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DebugPage(
            key: key,
            evaluate: (_) => {'pending': response.future},
          ),
        ),
      ),
    );
    await key.currentState!.run();
    await tester.pumpWidget(const SizedBox.shrink());
    final reference = _Reference();
    response.completeError({'detached descendant rejection': reference});
    await tester.pump();
    expect(reference.destroys, 1);
    expect(Log.logs.last.content, contains('detached descendant rejection'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('debug result aliases and map keys release each reference once', (
    tester,
  ) async {
    final alias = _Reference();
    final keyOnly = _Reference();
    final graph = <Object, Object?>{
      keyOnly: 'key value',
      'first': alias,
      'others': [alias, alias],
    };
    graph['self'] = graph;
    final key = GlobalKey<DebugPageState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DebugPage(key: key, evaluate: (_) => graph),
        ),
      ),
    );
    await key.currentState!.run();
    expect([alias.destroys, keyOnly.destroys], [1, 1]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('debug rejection releases references after the page leaves', (
    tester,
  ) async {
    final reference = _Reference();
    final response = Completer<Object?>();
    final key = GlobalKey<DebugPageState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DebugPage(key: key, evaluate: (_) => response.future),
        ),
      ),
    );
    final running = key.currentState!.run();
    await tester.pumpWidget(const SizedBox.shrink());
    response.completeError({'failure': reference, 'alias': reference});
    await running;
    expect(reference.destroys, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('default timeout cannot let the old result overwrite a new run', (
    tester,
  ) async {
    final lateReference = _Reference();
    var response = Completer<Object?>();
    final original = response;
    final key = GlobalKey<DebugPageState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DebugPage(key: key, evaluate: (_) => response.future),
        ),
      ),
    );
    final first = key.currentState!.run();
    await tester.pump(const Duration(seconds: 29));
    expect(key.currentState!.running, isTrue);
    await tester.pump(const Duration(seconds: 1));
    await first;
    expect(key.currentState!.running, isFalse);
    expect(key.currentState!.result, contains('TimeoutException'));
    response = Completer<Object?>();
    final second = key.currentState!.run();
    response.complete('current result');
    await second;
    original.complete({'late': lateReference});
    await tester.pump();
    expect(lateReference.destroys, 1);
    expect(key.currentState!.result, 'current result');
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('one release failure does not skip other rejected references', (
    tester,
  ) async {
    final broken = _Reference(failure: StateError('release failed'));
    final other = _Reference();
    final key = GlobalKey<DebugPageState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DebugPage(
            key: key,
            evaluate: (_) => throw {
              'original rejection': [broken, other],
            },
          ),
        ),
      ),
    );
    await key.currentState!.run();
    expect([broken.destroys, other.destroys], [1, 1]);
    expect(key.currentState!.result, contains('original rejection'));
    expect(key.currentState!.result, contains('release failed'));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
