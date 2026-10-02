import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/settings/data_sync_schedule_fields.dart';
import 'package:venera_next/foundation/sync_configuration.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/translations.dart';

void main() {
  for (final size in [const Size(320, 640), const Size(800, 360)]) {
    for (final brightness in Brightness.values) {
      testWidgets('sync fields support $size, $brightness and large text', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final previous = appdata.settings['language'];
        appdata.settings['language'] = 'zh-CN';
        addTearDown(() => appdata.settings['language'] = previous);
        await AppTranslation.init();
        var mode = DataSyncMode.manual;
        var minutes = 30;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: MediaQuery(
              data: MediaQueryData(
                size: size,
                textScaler: const TextScaler.linear(2),
              ),
              child: Scaffold(
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: StatefulBuilder(
                    builder: (context, setState) => DataSyncScheduleFields(
                      mode: mode,
                      minutes: minutes,
                      onModeChanged: (value) => setState(() => mode = value),
                      onIntervalChanged: (value) =>
                          setState(() => minutes = value),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        expect(find.byType(DropdownButton<int>), findsNothing);
        await tester.tap(find.byType(DropdownButton<DataSyncMode>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('定时同步').last);
        await tester.pumpAndSettle();
        expect(mode, DataSyncMode.scheduled);
        expect(find.byType(DropdownButton<int>), findsOneWidget);
        await tester.ensureVisible(find.byType(DropdownButton<int>));
        await tester.tap(find.byType(DropdownButton<int>));
        await tester.pumpAndSettle();
        await tester.tap(
          find.text('@minutes min'.tlParams({'minutes': 60})).last,
        );
        await tester.pumpAndSettle();
        expect(minutes, 60);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
