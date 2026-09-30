import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/loading.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/network/request_scope.dart';

class _Probe extends StatefulWidget {
  const _Probe({super.key, required this.load, this.loaded});
  final Future<Res<String>> Function(RequestScope) load;
  final Future<void> Function(RequestScope, String)? loaded;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends LoadingState<_Probe, String> {
  @override
  Future<Res<String>> loadData(RequestScope scope) => widget.load(scope);
  @override
  Future<void> onDataLoaded(RequestScope scope) async {
    await widget.loaded?.call(scope, data!);
  }

  @override
  Widget buildLoading() => const Text('loading');
  @override
  Widget buildError() => Text(error!);
  @override
  Widget buildContent(BuildContext context, String data) => Text(data);
}

void main() {
  Widget host(_Probe child) => MaterialApp(home: child);

  testWidgets('unmount cancels request and ignores late success', (
    tester,
  ) async {
    final response = Completer<Res<String>>();
    late RequestScope request;
    var notifications = 0;
    await tester.pumpWidget(
      host(
        _Probe(
          load: (scope) {
            request = scope;
            expect(RequestScope.current, same(scope));
            return response.future;
          },
          loaded: (scope, data) async => notifications++,
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox());
    expect(request.cancelToken.isCancelled, true);
    response.complete(const Res('late'));
    await tester.pump();
    expect(notifications, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retry replaces pending request and keeps newest result', (
    tester,
  ) async {
    final key = GlobalKey<_ProbeState>();
    final requests = <RequestScope>[];
    final responses = <Completer<Res<String>>>[];
    await tester.pumpWidget(
      host(
        _Probe(
          key: key,
          load: (scope) {
            requests.add(scope);
            final response = Completer<Res<String>>();
            responses.add(response);
            return response.future;
          },
        ),
      ),
    );
    key.currentState!.retry();
    await tester.pump();
    expect(requests.first.isCancelled, true);
    responses.last.complete(const Res('new'));
    await tester.pump();
    responses.first.complete(const Res('old'));
    await tester.pump();
    expect(find.text('new'), findsOneWidget);
    expect(find.text('old'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('automatic retries keep the four-attempt budget', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(
      host(
        _Probe(
          load: (scope) async {
            attempts++;
            return const Res.error('offline');
          },
        ),
      ),
    );
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pump();
    expect(attempts, 4);
    expect(find.text('offline'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(attempts, 4);
  });

  testWidgets('unmount cancels retry delay without another source call', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      host(
        _Probe(
          load: (scope) async {
            attempts++;
            return const Res.error('offline');
          },
        ),
      ),
    );
    expect(attempts, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(attempts, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'late post-load hook cannot publish after replacement or unmount',
    (tester) async {
      final key = GlobalKey<_ProbeState>();
      final gates = <Completer<void>>[];
      final effects = <String>[];
      var calls = 0;
      await tester.pumpWidget(
        host(
          _Probe(
            key: key,
            load: (scope) async => Res('value-${++calls}'),
            loaded: (scope, data) async {
              final gate = Completer<void>();
              gates.add(gate);
              await gate.future;
              scope.check();
              effects.add(data);
            },
          ),
        ),
      );
      expect(gates, hasLength(1));
      key.currentState!.retry();
      await tester.pump();
      gates.first.complete();
      await tester.pump();
      expect(effects, isEmpty);
      expect(find.text('loading'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      gates.last.complete();
      await tester.pump();
      expect(effects, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('thrown errors are visible and manual retry can recover', (
    tester,
  ) async {
    final previousMuted = Log.isMuted;
    Log.isMuted = true;
    addTearDown(() => Log.isMuted = previousMuted);
    final key = GlobalKey<_ProbeState>();
    var attempts = 0;
    await tester.pumpWidget(
      host(
        _Probe(
          key: key,
          load: (scope) async {
            if (attempts++ == 0) throw StateError('failed');
            return const Res('recovered');
          },
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Bad state: failed'), findsOneWidget);
    expect(tester.takeException(), isNull);
    key.currentState!.retry();
    await tester.pump();
    expect(find.text('recovered'), findsOneWidget);
  });
}
