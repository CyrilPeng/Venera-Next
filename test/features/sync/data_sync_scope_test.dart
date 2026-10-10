import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/sync/sync.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/sync_preference_store.dart';

void main() {
  testWidgets('summary follows replacement controller and releases listeners', (
    tester,
  ) async {
    final first = _Controller();
    final second = _Controller();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    Widget app(DataSyncController controller) => MaterialApp(
      home: DataSyncScope(
        controller: controller,
        child: const Scaffold(
          body: CustomScrollView(slivers: [SyncStatusSummary()]),
        ),
      ),
    );
    await tester.pumpWidget(app(first));
    expect(first.isObserved, isTrue);
    await tester.tap(find.byTooltip('Upload'));
    expect(first.uploads, 1);
    await tester.pumpWidget(app(second));
    expect(first.isObserved, isFalse);
    expect(second.isObserved, isTrue);
    await tester.tap(find.byTooltip('Download'));
    expect(second.downloads, 1);
    expect(first.downloads, 0);
    second.setVisible(false);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Download'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    expect(second.isObserved, isFalse);
    // Detaching the scope does not dispose its application-owned controller.
    second.setVisible(true);
    await tester.pumpWidget(app(second));
    expect(find.byTooltip('Download'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('missing scope reports an explicit composition error', (
    tester,
  ) async {
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          DataSyncScope.of(context);
          return const SizedBox();
        },
      ),
    );
    expect(tester.takeException(), isA<StateError>());
  });
}

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

  bool get isObserved => hasListeners;

  int uploads = 0;
  int downloads = 0;
  bool visible = true;

  void setVisible(bool value) {
    visible = value;
    notifyListeners();
  }

  @override
  DataSyncStatusSnapshot get statusSnapshot => DataSyncStatusSnapshot(
    isConfigured: visible,
    isEnabled: false,
    isUploading: false,
    isDownloading: false,
    lastSyncTime: 0,
    lastError: null,
  );

  @override
  Future<Res<bool>> uploadData() async {
    uploads++;
    return const Res(true);
  }

  @override
  Future<Res<bool>> downloadData({bool force = false}) async {
    downloads++;
    return const Res(true);
  }
}
