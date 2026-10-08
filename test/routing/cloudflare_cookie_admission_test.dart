import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/routing/app_navigation.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/cloudflare.dart';
import 'package:venera_next/network/cookie_jar.dart';
import 'package:venera_next/routing/cloudflare.dart';

void main() {
  for (final missing in [false, true]) {
    testWidgets(
      'Cloudflare capture does not open a webview after unmount; missing=$missing',
      (tester) async {
        final directory = Directory.systemTemp.createTempSync(
          'cloudflare-cookie-',
        );
        final previous = SingleInstanceCookieJar.instance;
        final muted = Log.isMuted;
        SingleInstanceCookieJar.instance = null;
        Log.isMuted = true;
        final messages = <String>[];
        registerShowMessageHandler((context, message) => messages.add(message));
        addTearDown(() {
          SingleInstanceCookieJar.instance?.dispose();
          SingleInstanceCookieJar.instance = previous;
          Log.isMuted = muted;
          registerShowMessageHandler((context, message) {});
          directory.deleteSync(recursive: true);
        });
        if (!missing) SingleInstanceCookieJar('${directory.path}/cookie.db');
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: appNavigation.rootNavigatorKey,
            home: const Scaffold(body: Text('source')),
          ),
        );
        final release = Completer<void>();
        final replacement = AppDataOperations.instance.run(
          () => release.future,
        );
        var completions = 0;
        passCloudflare(
          CloudflareException('https://example.test/'),
          () => completions++,
        );
        await tester.pump();
        expect(completions, 0);
        await tester.pumpWidget(const SizedBox());
        release.complete();
        await tester.pumpAndSettle();
        await replacement;
        expect(completions, 1);
        expect(messages, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
