import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/status_info.dart';

void main() {
  testWidgets(
    'stalled battery query does not overlap and ignores exit result',
    (tester) async {
      final pending = Completer<ReaderBatterySnapshot?>();
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderStatusInfo(
            readBattery: () {
              calls++;
              return pending.future;
            },
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 5));
      expect(calls, 1);
      await tester.pumpWidget(const SizedBox());
      pending.complete(const ReaderBatterySnapshot(50, charging: false));
      await tester.pump(const Duration(seconds: 5));
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'transient errors recover and charging updates without level change',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderStatusInfo(
            readBattery: () async {
              calls++;
              if (calls == 1 || calls == 3) {
                throw StateError('temporarily unavailable');
              }
              return ReaderBatterySnapshot(0, charging: calls >= 4);
            },
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('0%'), findsNWidgets(2));
      expect(find.byIcon(Icons.battery_alert_sharp), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('0%'), findsNWidgets(2));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byIcon(Icons.battery_charging_full), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'replacement rejects old query and unsupported battery stops polling',
    (tester) async {
      final old = Completer<ReaderBatterySnapshot?>();
      await tester.pumpWidget(
        MaterialApp(home: ReaderStatusInfo(readBattery: () => old.future)),
      );
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderStatusInfo(
            readBattery: () async {
              calls++;
              return null;
            },
          ),
        ),
      );
      old.complete(const ReaderBatterySnapshot(99, charging: true));
      await tester.pump(const Duration(seconds: 3));
      expect(calls, 1);
      expect(find.text('99%'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('clock advances independently while battery is waiting', (
    tester,
  ) async {
    var now = DateTime(2026, 10, 1, 9, 59);
    final pending = Completer<ReaderBatterySnapshot?>();
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderStatusInfo(
          now: () => now,
          readBattery: () => pending.future,
        ),
      ),
    );
    expect(find.text('09:59'), findsNWidgets(2));
    now = DateTime(2026, 10, 1, 10);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('10:00'), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox());
    pending.completeError(StateError('late platform error'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
