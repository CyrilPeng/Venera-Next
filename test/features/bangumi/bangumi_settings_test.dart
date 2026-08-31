import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/bangumi/bangumi.dart';
import 'package:venera_next/foundation/appdata.dart';

void main() {
  tearDown(() {
    appdata.settings['bangumiAccessToken'] = '';
    appdata.settings['bangumiUsername'] = '';
    appdata.settings['bangumiAutoSyncEnabled'] = true;
    appdata.settings['bangumiBindings'] = <String, dynamic>{};
  });

  testWidgets('settings masks token and opens the application page', (
    tester,
  ) async {
    appdata.settings['bangumiAccessToken'] = 'token';
    appdata.settings['bangumiUsername'] = 'alice';
    Uri? launched;

    await tester.pumpWidget(
      MaterialApp(
        home: BangumiSettingsPage(
          service: BangumiService.forTesting(gatewayFactory: (_) => _Gateway()),
          launchTokenPage: (uri) async {
            launched = uri;
            return true;
          },
        ),
      ),
    );

    final tokenField = tester.widget<TextField>(
      find.byKey(const Key('bangumi-token-field')),
    );
    expect(tokenField.obscureText, isTrue);
    await tester.tap(find.byKey(const Key('bangumi-apply-token')));
    await tester.pump();
    expect(launched, Uri.parse('https://next.bgm.tv/demo/access-token'));
  });

  testWidgets('retrying the token page clears a previous launch error', (
    tester,
  ) async {
    var canLaunch = false;
    await tester.pumpWidget(
      MaterialApp(
        home: BangumiSettingsPage(
          service: BangumiService.forTesting(gatewayFactory: (_) => _Gateway()),
          launchTokenPage: (_) async => canLaunch,
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('bangumi-apply-token')));
    await tester.pumpAndSettle();
    expect(find.text('Failed to open Access Token page'), findsOneWidget);

    canLaunch = true;
    await tester.tap(find.byKey(const Key('bangumi-apply-token')));
    await tester.pumpAndSettle();
    expect(find.text('Failed to open Access Token page'), findsNothing);
  });

  testWidgets('connect displays the verified username', (tester) async {
    var changes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: BangumiSettingsPage(
          service: BangumiService.forTesting(gatewayFactory: (_) => _Gateway()),
          onConnectionChanged: () => changes++,
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('bangumi-token-field')),
      ' token ',
    );
    await tester.tap(find.byKey(const Key('bangumi-connect')));
    await tester.pumpAndSettle();

    expect(appdata.settings['bangumiAccessToken'], 'token');
    expect(appdata.settings['bangumiUsername'], 'alice');
    expect(find.text('alice'), findsOneWidget);
    expect(changes, 1);
  });

  testWidgets('failed connection keeps the entered token', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BangumiSettingsPage(
          service: BangumiService.forTesting(
            gatewayFactory: (_) => _Gateway(shouldFail: true),
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('bangumi-token-field')),
      'token',
    );
    await tester.tap(find.byKey(const Key('bangumi-connect')));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<TextField>(find.byKey(const Key('bangumi-token-field')))
          .controller!
          .text,
      'token',
    );
    expect(appdata.settings['bangumiAccessToken'], isEmpty);
    expect(
      find.textContaining('Failed to connect to Bangumi:'),
      findsOneWidget,
    );
  });

  testWidgets('empty token is rejected without calling Bangumi', (
    tester,
  ) async {
    final gateway = _Gateway();
    await tester.pumpWidget(
      MaterialApp(
        home: BangumiSettingsPage(
          service: BangumiService.forTesting(gatewayFactory: (_) => gateway),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('bangumi-connect')));
    await tester.pumpAndSettle();

    expect(gateway.currentUserCalls, 0);
    expect(find.text('Access Token cannot be empty'), findsOneWidget);
  });

  testWidgets('authentication failure marks the connection invalid', (
    tester,
  ) async {
    appdata.settings['bangumiAccessToken'] = 'saved-token';
    appdata.settings['bangumiUsername'] = 'alice';
    await tester.pumpWidget(
      MaterialApp(
        home: BangumiSettingsPage(
          service: BangumiService.forTesting(
            gatewayFactory: (_) => _Gateway(authenticationFailure: true),
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('bangumi-token-field')),
      'new-token',
    );
    await tester.tap(find.byKey(const Key('bangumi-connect')));
    await tester.pumpAndSettle();

    expect(appdata.settings['bangumiAccessToken'], 'saved-token');
    expect(appdata.settings['bangumiUsername'], 'alice');
    expect(
      find.text(
        'Bangumi connection is invalid. Please check your Access Token.',
      ),
      findsOneWidget,
    );
    expect(find.text('alice'), findsNothing);
  });

  testWidgets('disconnect clears the saved connection only', (tester) async {
    appdata.settings['bangumiAccessToken'] = 'token';
    appdata.settings['bangumiUsername'] = 'alice';
    appdata.settings['bangumiBindings'] = {
      'source@comic': {'subjectId': 42},
    };
    await tester.pumpWidget(
      MaterialApp(
        home: BangumiSettingsPage(
          service: BangumiService.forTesting(gatewayFactory: (_) => _Gateway()),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('bangumi-disconnect')));
    await tester.pumpAndSettle();

    expect(appdata.settings['bangumiAccessToken'], isEmpty);
    expect(appdata.settings['bangumiUsername'], isEmpty);
    expect(appdata.settings['bangumiBindings'], isNotEmpty);
  });

  testWidgets('automatic sync switch saves its setting without API access', (
    tester,
  ) async {
    var saves = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: BangumiSettingsPage(
          service: BangumiService.forTesting(gatewayFactory: (_) => _Gateway()),
          saveSettings: () async => saves++,
        ),
      ),
    );

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(appdata.settings['bangumiAutoSyncEnabled'], isFalse);
    expect(saves, 1);
  });

  testWidgets('automatic sync switch ignores a second in-flight change', (
    tester,
  ) async {
    final save = Completer<void>();
    var saves = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: BangumiSettingsPage(
          service: BangumiService.forTesting(gatewayFactory: (_) => _Gateway()),
          saveSettings: () {
            saves++;
            return save.future;
          },
        ),
      ),
    );

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(saves, 1);
    save.complete();
    await tester.pumpAndSettle();
    expect(appdata.settings['bangumiAutoSyncEnabled'], isFalse);
  });

  testWidgets('invalid synced setting types fall back safely', (tester) async {
    appdata.settings['bangumiAccessToken'] = 42;
    appdata.settings['bangumiUsername'] = <String>[];
    appdata.settings['bangumiAutoSyncEnabled'] = 'invalid';

    await tester.pumpWidget(
      MaterialApp(
        home: BangumiSettingsPage(
          service: BangumiService.forTesting(gatewayFactory: (_) => _Gateway()),
        ),
      ),
    );

    expect(
      tester
          .widget<TextField>(find.byKey(const Key('bangumi-token-field')))
          .controller!
          .text,
      isEmpty,
    );
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('failed automatic sync save restores the switch and setting', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BangumiSettingsPage(
          service: BangumiService.forTesting(gatewayFactory: (_) => _Gateway()),
          saveSettings: () async => throw StateError('save failed'),
        ),
      ),
    );

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(appdata.settings['bangumiAutoSyncEnabled'], isTrue);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(
      find.textContaining('Failed to save Bangumi settings:'),
      findsOneWidget,
    );
  });

  testWidgets('successful automatic sync retry clears a previous save error', (
    tester,
  ) async {
    var fails = true;
    await tester.pumpWidget(
      MaterialApp(
        home: BangumiSettingsPage(
          service: BangumiService.forTesting(gatewayFactory: (_) => _Gateway()),
          saveSettings: () async {
            if (fails) throw StateError('save failed');
          },
        ),
      ),
    );

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Failed to save Bangumi settings:'),
      findsOneWidget,
    );

    fails = false;
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(appdata.settings['bangumiAutoSyncEnabled'], isFalse);
    expect(
      find.textContaining('Failed to save Bangumi settings:'),
      findsNothing,
    );
  });

  testWidgets(
    'disposed settings page does not clear a disposed token controller',
    (tester) async {
      appdata.settings['bangumiAccessToken'] = 'token';
      appdata.settings['bangumiUsername'] = 'alice';
      final save = Completer<void>();
      var changes = 0;
      final service = BangumiService.forTesting(
        gatewayFactory: (_) => _Gateway(),
        saveSettings: () => save.future,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: BangumiSettingsPage(
            service: service,
            onConnectionChanged: () => changes++,
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('bangumi-disconnect')));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      save.complete();
      await tester.pumpAndSettle();
      expect(changes, 1);
    },
  );

  test('Bangumi entry precedes data sync entry', () {
    final source = File('lib/features/settings/app.dart').readAsStringSync();
    expect(
      source.indexOf("Key('bangumi-settings-entry')"),
      greaterThanOrEqualTo(0),
    );
    expect(
      source.indexOf("Key('bangumi-settings-entry')"),
      lessThan(source.indexOf("Key('data-sync-entry')")),
    );
  });
}

class _Gateway implements BangumiGateway {
  _Gateway({this.shouldFail = false, this.authenticationFailure = false});

  final bool shouldFail;
  final bool authenticationFailure;
  int currentUserCalls = 0;

  @override
  Future<BangumiUser> currentUser() async {
    currentUserCalls++;
    if (authenticationFailure) {
      throw const BangumiApiException(401, 'Unauthorized');
    }
    if (shouldFail) throw StateError('invalid token');
    return const BangumiUser('alice', 'Alice');
  }

  @override
  Future<void> createCollection(int subjectId, Map<String, dynamic> fields) =>
      throw UnsupportedError('unused');

  @override
  Future<BangumiSubject> getSubject(int subjectId) =>
      throw UnsupportedError('unused');

  @override
  Future<BangumiCollection?> getCollection(String username, int subjectId) =>
      throw UnsupportedError('unused');

  @override
  Future<void> patchCollection(int subjectId, Map<String, dynamic> fields) =>
      throw UnsupportedError('unused');

  @override
  Future<List<BangumiSubject>> searchSubjects(String keyword) =>
      throw UnsupportedError('unused');
}
