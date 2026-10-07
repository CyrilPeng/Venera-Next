import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_next/components/menu.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// The real serializer is an existing transitive share_plus dependency.
// ignore: depend_on_referenced_packages
import 'package:share_plus_platform_interface/method_channel/method_channel_share.dart';
// ignore: depend_on_referenced_packages
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/features/comic_details/actions.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/file_interaction.dart' show Share;
import 'package:venera_next/foundation/log.dart';
import 'package:window_manager/window_manager.dart';

class _Actions with ComicPageActions {
  @override
  final contextMenus = MenuRouteController();
  _Actions(this.context);
  @override
  final BuildContext context;
  @override
  ComicDetails comic = _comic('One', 'one');
  @override
  History? get history => null;
  @override
  bool isComicActive(ComicDetails value) =>
      context.mounted && identical(comic, value);
  @override
  void update() {}
  @override
  void onReadEnd() {}
}

ComicDetails _comic(String title, String id) => ComicDetails.fromJson({
  'title': title,
  'cover': '',
  'tags': {},
  'sourceKey': 'test',
  'comicId': id,
  'url': 'https://example.test/$id',
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  final replies = <Completer<String?>>[];
  final messages = <({BuildContext context, String message})>[];
  late SharePlatform previousPlatform;
  late bool previousMuted;
  setUpAll(() {
    previousPlatform = SharePlatform.instance;
    SharePlatform.instance = MethodChannelShare();
  });
  tearDownAll(() => SharePlatform.instance = previousPlatform);
  setUp(() {
    calls.clear();
    replies.clear();
    messages.clear();
    previousMuted = Log.isMuted;
    Log.isMuted = true;
    registerShowMessageHandler((context, message) {
      messages.add((context: context, message: message));
      showToast(message: message, context: context);
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (_) async => false,
    );
    messenger.setMockMethodCallHandler(MethodChannelShare.channel, (call) {
      calls.add(call);
      final reply = Completer<String?>();
      replies.add(reply);
      return reply.future;
    });
  });
  tearDown(() {
    Log.isMuted = previousMuted;
    registerShowMessageHandler((context, message) {});
    messenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      null,
    );
    messenger.setMockMethodCallHandler(MethodChannelShare.channel, null);
  });

  Future<
    ({
      GlobalKey<NavigatorState> navigator,
      WindowFrameController frame,
      _Actions actions,
    })
  >
  mount(WidgetTester tester, {required VoidCallback onExit}) async {
    final navigator = GlobalKey<NavigatorState>();
    late WindowFrameController frame;
    late _Actions actions;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        builder: (_, child) =>
            WindowFrame(OverlayWidget(child!), onExit: onExit),
        home: Builder(
          builder: (context) {
            frame = WindowFrame.of(context);
            return const Scaffold(body: Text('Home'));
          },
        ),
      ),
    );
    navigator.currentState!.push<void>(
      MaterialPageRoute(
        builder: (context) {
          actions = _Actions(context);
          return const Scaffold(body: Text('Comic page'));
        },
      ),
    );
    await tester.pumpAndSettle();
    return (navigator: navigator, frame: frame, actions: actions);
  }

  void close(WidgetTester tester) =>
      (tester.state(find.byType(WindowFrame)) as WindowListener)
          .onWindowClose();

  testWidgets(
    'duplicate actions share original Future and snapshot queued title, URL and origin',
    (tester) async {
      final host = await mount(tester, onExit: () {});
      final blocker = (await _start(
        tester,
        () => Share.shareText('earlier dialog'),
      )).done;
      await _flush(tester);
      expect(calls, hasLength(1));
      final original = (await _start(tester, host.actions.share)).done;
      expect(host.actions.share(), same(original));
      final oldOrigin = host.actions.context.sharePositionOrigin;
      tester.view.physicalSize = const Size(600, 700);
      addTearDown(tester.view.resetPhysicalSize);
      await _flush(tester);
      final newOrigin = host.actions.context.sharePositionOrigin;
      expect(newOrigin, isNot(oldOrigin));
      expect(calls, hasLength(1));
      replies[0].complete('first');
      await _flush(tester);
      await tester.runAsync(() => blocker);
      expect(calls, hasLength(2));
      final args = calls[1].arguments as Map;
      expect(args['text'], 'One\nhttps://example.test/one');
      expect(args['originWidth'], greaterThan(0));
      expect(args['originHeight'], greaterThan(0));
      expect(args['originWidth'], newOrigin.width);
      expect(args['originHeight'], newOrigin.height);
      replies[1].complete('shared');
      await _flush(tester);
      await tester.runAsync(() => original);
      host.actions.comic = _comic('Two', 'two');
      final next = (await _start(tester, host.actions.share)).done;
      await _flush(tester);
      expect(calls[2].arguments['text'], 'Two\nhttps://example.test/two');
      replies[2].complete('shared');
      await _flush(tester);
      await tester.runAsync(() => next);
      expect(messages, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'forced page unmount leaves window waiting for native acknowledgement',
    (tester) async {
      var exits = 0;
      final host = await mount(tester, onExit: () => exits++);
      final sharing = (await _start(tester, host.actions.share)).done;
      await _flush(tester);
      host.navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(host.actions.context.mounted, isFalse);
      close(tester);
      await _flush(tester);
      expect(exits, 0);
      expect(find.text('Closing...'), findsOneWidget);
      replies.single.complete('native completed');
      await _flush(tester);
      await tester.runAsync(() => sharing);
      await tester.pumpAndSettle();
      expect(exits, 1);
      expect(messages, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'closing window refuses a new comic share before native admission',
    (tester) async {
      final wait = Completer<void>();
      var exits = 0;
      final host = await mount(tester, onExit: () => exits++);
      host.frame.addExitTask(() => wait.future);
      close(tester);
      await host.actions.share();
      await _flush(tester);
      expect(calls, isEmpty);
      wait.complete();
      await tester.pumpAndSettle();
      expect(exits, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'late share failure blocks close with original cause and allows retry after recovery',
    (tester) async {
      var exits = 0;
      final host = await mount(tester, onExit: () => exits++);
      final captured = _capture(
        (await _start(tester, host.actions.share)).done,
      );
      await _flush(tester);
      close(tester);
      await _flush(tester);
      final reported = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (details) {
        reported.add(details);
        previous?.call(details);
      };
      try {
        replies.single.completeError(
          PlatformException(code: 'share-late', details: {'origin': 'native'}),
        );
        await _flush(tester);
        final failure = (await tester.runAsync(() => captured))!;
        expect(tester.takeException(), same(failure.error));
        expect(reported.single.exception, same(failure.error));
        expect(reported.single.stack.toString(), failure.stack.toString());
        expect((failure.error as PlatformException).code, 'share-late');
      } finally {
        FlutterError.onError = previous;
      }
      expect(exits, 0);
      expect(messages, isEmpty);
      final retry = (await _start(tester, host.actions.share)).done;
      await _flush(tester);
      expect(calls, hasLength(2));
      replies[1].complete('recovered');
      await _flush(tester);
      await tester.runAsync(() => retry);
      close(tester);
      await tester.pumpAndSettle();
      expect(exits, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'ordinary failure renders Error on active owner and permits another share',
    (tester) async {
      final host = await mount(tester, onExit: () {});
      final sharing = (await _start(tester, host.actions.share)).done;
      await _flush(tester);
      replies.single.completeError(PlatformException(code: 'ordinary-failure'));
      await _flush(tester);
      await tester.runAsync(() => sharing);
      expect(messages.single.context, same(host.actions.context));
      expect(messages.single.message, 'Error');
      expect(find.text('Error'), findsOneWidget);
      final retry = (await _start(tester, host.actions.share)).done;
      await _flush(tester);
      replies[1].complete('ok');
      await _flush(tester);
      await tester.runAsync(() => retry);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'stale failure reports its cause without notifying a replacement comic',
    (tester) async {
      final host = await mount(tester, onExit: () {});
      final failed = _capture((await _start(tester, host.actions.share)).done);
      await _flush(tester);
      final replacement = _comic('Replacement', 'replacement');
      host.actions.comic = replacement;
      replies.single.completeError(PlatformException(code: 'old-comic'));
      await _flush(tester);
      final failure = (await tester.runAsync(() => failed))!;
      expect(tester.takeException(), same(failure.error));
      expect(messages, isEmpty);
      expect(host.actions.comic, same(replacement));
      final retry = (await _start(tester, host.actions.share)).done;
      await _flush(tester);
      expect(
        calls[1].arguments['text'],
        'Replacement\nhttps://example.test/replacement',
      );
      replies[1].complete('ok');
      await _flush(tester);
      await tester.runAsync(() => retry);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final invalidation in ['unmount', 'replacement', 'window close']) {
    testWidgets(
      'queued text is cancelled before native dispatch after $invalidation',
      (tester) async {
        var exits = 0;
        final host = await mount(tester, onExit: () => exits++);
        final blocker = (await _start(
          tester,
          () => Share.shareText('active native dialog'),
        )).done;
        await _flush(tester);
        final queued = (await _start(tester, host.actions.share)).done;
        await _flush(tester);
        expect(calls, hasLength(1));
        switch (invalidation) {
          case 'unmount':
            host.navigator.currentState!.pop();
            await tester.pumpAndSettle();
          case 'replacement':
            host.actions.comic = _comic('New comic', 'new');
          case 'window close':
            close(tester);
            await _flush(tester);
            expect(exits, 0);
        }
        replies.single.complete('acknowledged');
        await _flush(tester);
        await tester.runAsync(() => blocker);
        await tester.runAsync(() => queued);
        await _flush(tester);
        expect(calls, hasLength(1));
        expect(messages, isEmpty);
        expect(exits, invalidation == 'window close' ? 1 : 0);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'popover origin stays nonzero inside an iPad-sized view after clipping',
    (tester) async {
      tester.view.physicalSize = const Size(2048, 1536);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late BuildContext source;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: Transform.translate(
                offset: const Offset(-20, 10),
                child: SizedBox(
                  width: 40,
                  height: 30,
                  child: Builder(
                    builder: (context) {
                      source = context;
                      return const SizedBox.expand();
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(source.sharePositionOrigin, const Rect.fromLTWH(0, 10, 20, 30));
      await tester.pumpWidget(const SizedBox());
      expect(() => source.sharePositionOrigin, throwsStateError);
    },
  );

  testWidgets('source without initial layout fails explicitly', (tester) async {
    Object? failure;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            try {
              context.sharePositionOrigin;
            } catch (error) {
              failure = error;
            }
            return const SizedBox(width: 30, height: 30);
          },
        ),
      ),
    );
    expect(failure, isA<StateError>());
    await tester.pumpWidget(const SizedBox());
  });

  for (final empty in [false, true]) {
    testWidgets('empty or off-view popover source fails; empty=$empty', (
      tester,
    ) async {
      late BuildContext source;
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: Transform.translate(
              offset: const Offset(2000, 2000),
              child: SizedBox(
                width: empty ? 0 : 40,
                height: empty ? 0 : 30,
                child: Builder(
                  builder: (context) {
                    source = context;
                    return const SizedBox.expand();
                  },
                ),
              ),
            ),
          ),
        ),
      );
      expect(() => source.sharePositionOrigin, throwsStateError);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

Future<({Object error, StackTrace stack})> _capture(
  Future<void> operation,
) async {
  try {
    await operation;
  } catch (error, stack) {
    return (error: error, stack: stack);
  }
  throw TestFailure('Expected share failure');
}

// The production queue is process-wide. Start it outside each widget test's
// FakeAsync zone so its completed tail remains usable by the next test.
Future<({Future<void> done})> _start(
  WidgetTester tester,
  Future<void> Function() action,
) async => (await tester.runAsync(() async => (done: action())))!;

Future<void> _flush(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}
