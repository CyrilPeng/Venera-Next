import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/sync/data_sync_controller.dart';
import 'package:venera_next/features/sync/data_sync_scope.dart';
import 'package:venera_next/features/sync/sync_status_summary.dart';
import 'package:venera_next/foundation/sync_preference_store.dart';

class _Controller extends DataSyncController {
  _Controller()
    : super(
        preferences: SyncPreferenceStore(
          readSetting: (_) => null,
          writeSetting: (_, _) {},
          implicitData: () => <String, dynamic>{},
        ),
        transfer: () => throw StateError('Unexpected transfer'),
        saveSettings: () async {},
        persistImplicit: () {},
        observeChanges: (_) => () {},
      );

  @override
  DataSyncStatusSnapshot get statusSnapshot => const DataSyncStatusSnapshot(
    isConfigured: true,
    isEnabled: false,
    isUploading: false,
    isDownloading: false,
    lastSyncTime: 0,
    lastError: 'Synthetic sync failure',
  );
}

void main() {
  testWidgets('sync error uses its mounted presentation context', (
    tester,
  ) async {
    final controller = _Controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: DataSyncScope(
          controller: controller,
          child: const Scaffold(
            body: CustomScrollView(slivers: [SyncStatusSummary()]),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Error'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Synthetic sync failure'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });
}
