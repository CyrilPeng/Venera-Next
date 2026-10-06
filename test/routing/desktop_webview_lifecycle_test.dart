import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/routing/webview.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('webview_window');
  Future<void> closed(int id) async {
    final done = Completer<void>();
    binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('onWindowClose', {'id': id}),
      ),
      (_) => done.complete(),
    );
    await done.future;
  }

  setUp(() {
    App.dataPath = 'webview-test';
    final proxy = appdata.settings['proxy'];
    appdata.settings['proxy'] = 'direct';
    addTearDown(() {
      appdata.settings['proxy'] = proxy;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });
  });

  testWidgets(
    'close during creation waits for the late window and its native close',
    (tester) async {
      final create = Completer<int>();
      var creates = 0;
      var closes = 0;
      var launches = 0;
      var started = 0;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'create') {
          creates++;
          return create.future;
        }
        if (call.method == 'close') closes++;
        if (call.method == 'launch') launches++;
        return null;
      });
      final view = DesktopWebview(
        initialUrl: 'https://example.test/',
        onStarted: (_) => started++,
      );
      final opening = view.open();
      expect(view.open(), same(opening));
      await tester.pump();
      var finished = false;
      final closing = view.close();
      closing.then((_) => finished = true);
      expect(view.close(), same(closing));
      create.complete(101);
      await tester.pump();
      expect(creates, 1);
      expect(closes, 1);
      expect(launches, 0);
      expect(finished, isFalse);
      await closed(101);
      await tester.pump(const Duration(seconds: 3));
      await Future.wait([opening, closing]);
      expect(started, 0);
    },
  );

  testWidgets('close waits for an accepted poll and drops its late title', (
    tester,
  ) async {
    final poll = Completer<String?>();
    var polls = 0;
    var titles = 0;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'create') return 102;
      if (call.method == 'evaluateJavaScript') {
        polls++;
        return poll.future;
      }
      return null;
    });
    final view = DesktopWebview(
      initialUrl: 'https://example.test/',
      onTitleChange: (_, _) => titles++,
    );
    final opening = view.open();
    await tester.pump();
    await opening;
    await tester.pump(const Duration(seconds: 2));
    expect(polls, 1);
    var finished = false;
    final closing = view.close().then((_) => finished = true);
    await tester.pump();
    await closed(102);
    await tester.pump();
    expect(finished, isFalse);
    poll.complete('{"id":"document_created","data":{"title":"old","ua":"ua"}}');
    await tester.pump(const Duration(seconds: 5));
    await closing;
    expect(titles, 0);
    expect(polls, 1);
  });

  testWidgets('natural close cancels the delayed started callback', (
    tester,
  ) async {
    var starts = 0;
    var closes = 0;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'create' ? 103 : null,
    );
    final view = DesktopWebview(
      initialUrl: 'https://example.test/',
      onStarted: (_) => starts++,
      onClose: () => closes++,
    );
    final opening = view.open();
    await tester.pump();
    await opening;
    await closed(103);
    await tester.pump(const Duration(seconds: 3));
    await view.close();
    expect(starts, 0);
    expect(closes, 1);
  });

  testWidgets('ignored creation and close errors remain observable to owners', (
    tester,
  ) async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'create') {
        throw PlatformException(code: 'create-failed');
      }
      return null;
    });
    final view = DesktopWebview(initialUrl: 'https://example.test/');
    view.open();
    await tester.pump();
    view.close();
    await tester.pump();
    await expectLater(view.open(), throwsA(isA<PlatformException>()));
    await expectLater(view.close(), throwsA(isA<PlatformException>()));
  });
}
