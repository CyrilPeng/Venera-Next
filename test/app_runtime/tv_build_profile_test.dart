import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/application_updates.dart';
import 'package:venera_next/components/tv_navigation.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_profile.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/tv_reader_policy.dart';

const _expectTv = bool.fromEnvironment('EXPECT_TV');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'the compiled flavor controls the actual application update service',
    () async {
      expect(AppProfile.current.isTv, _expectTv);
      final updates = createApplicationUpdates();
      expect(updates.forAndroidTv, _expectTv);
      if (_expectTv) {
        expect(AppProfile.current.build, 'ci-test');
        expect(AppProfile.current.revision, 'tv-test');
      }
      await updates.closeAndWait();
    },
  );

  test(
    'the compiled flavor overlays local settings without rewriting them',
    () async {
      final before = appdata.captureImportCheckpoint();
      final directory = Directory.systemTemp.createTempSync('tv-profile-');
      App.dataPath = directory.path;
      try {
        appdata.settings['readerMode'] = 'waterfallTopToBottom';
        appdata.settings['autoReaderMode'] = true;
        appdata.settings['preloadImageCount'] = 12;
        appdata.settings[TvReaderPolicy.lowMemory.key] = true;
        expect(appdata.settings.tvLowMemoryEnabled, _expectTv);
        expect(
          appdata.settings.globalReaderSettings.readerMode,
          _expectTv ? 'galleryLeftToRight' : 'waterfallTopToBottom',
        );
        expect(
          appdata.settings.globalReaderSettings.preloadImageCount,
          _expectTv ? 1 : 12,
        );
        expect(appdata.settings['readerMode'], 'waterfallTopToBottom');
        expect(appdata.settings['preloadImageCount'], 12);
        appdata.settings[TvReaderPolicy.lowMemory.key] = false;
        expect(appdata.settings.tvLowMemoryEnabled, isFalse);
        expect(
          appdata.settings.globalReaderSettings.readerMode,
          'waterfallTopToBottom',
        );
        expect(appdata.settings.globalReaderSettings.preloadImageCount, 12);
      } finally {
        await appdata.restoreImportCheckpoint(before, persist: false);
        directory.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'navigation defaults to the actual build rather than screen size',
    (tester) async {
      late MediaQueryData media;
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => TvNavigation(child: child!),
          home: Builder(
            builder: (context) {
              media = MediaQuery.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(
        media.navigationMode,
        _expectTv ? NavigationMode.directional : NavigationMode.traditional,
      );
      expect(media.padding.left, _expectTv ? 24 : 0);
    },
  );
}
