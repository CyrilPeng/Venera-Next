import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/sync_window_binding.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/features/sync/sync.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/res.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    DataSync.resetForTesting();
    appdata.implicitData['webdavAutoSync'] = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => false,
        );
  });
  tearDown(() {
    DataSync.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });

  for (final removeBeforeComplete in [false, true]) {
    testWidgets(
      'window close waits for upload; removed=$removeBeforeComplete',
      (tester) async {
        final pending = Completer<Res<bool>>();
        DataSync.debugUploadOverride = () => pending.future;
        final upload = DataSync().uploadData();
        var exits = 0;
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: App.rootNavigatorKey,
            builder: (context, child) => WindowFrame(
              SyncWindowBinding(onExit: () => exits++, child: child!),
            ),
            home: const Scaffold(body: Text('content')),
          ),
        );
        await tester.pump();
        // Invoke the close button directly so the modal cannot hide duplicate clicks.
        final close = tester
            .widgetList<WindowButton>(find.byType(WindowButton))
            .last;
        close.onPressed();
        close.onPressed();
        await tester.pump();
        expect(exits, 0);
        if (removeBeforeComplete) await tester.pumpWidget(const SizedBox());
        pending.complete(const Res(true));
        await upload;
        await tester.pump();
        expect(exits, removeBeforeComplete ? 0 : 1);
        await tester.pumpWidget(const SizedBox());
      },
      skip: !Platform.isWindows,
    ); // Custom Windows title-bar behavior.
  }
}
