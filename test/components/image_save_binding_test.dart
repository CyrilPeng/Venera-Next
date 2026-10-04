import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/image_save_binding.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/foundation/image_save_work.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final bytes = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (_) async => false,
    );
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      null,
    );
  });

  void close(WidgetTester tester) =>
      (tester.state(find.byType(WindowFrame)) as WindowListener)
          .onWindowClose();

  Future<WindowFrameController> mount(
    WidgetTester tester,
    ValueNotifier<Widget> content, {
    required VoidCallback onExit,
  }) async {
    late WindowFrameController frame;
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => WindowFrame(child!, onExit: onExit),
        home: Builder(
          builder: (context) {
            frame = WindowFrame.of(context);
            return Scaffold(
              body: ValueListenableBuilder<Widget>(
                valueListenable: content,
                builder: (_, value, _) => value,
              ),
            );
          },
        ),
      ),
    );
    return frame;
  }

  testWidgets(
    'window close freezes admission before exit tasks and joins original read',
    (tester) async {
      final reading = Completer<Uint8List>();
      final earlierExit = Completer<void>();
      var deliveries = 0;
      var exits = 0;
      final work = ImageSaveWork(
        deliver: (_, _, _) async {
          deliveries++;
          return true;
        },
        onError: (error, _) => fail('$error'),
      );
      final content = ValueNotifier<Widget>(
        ImageSaveBinding(work: work, child: const Text('Owner')),
      );
      addTearDown(content.dispose);
      final frame = await mount(tester, content, onExit: () => exits++);
      final saving = work.save(read: (_) => reading.future, name: 'original');
      // Reverse exit order intentionally delays the binding's prepare callback.
      frame.addExitTask(() => earlierExit.future);
      close(tester);
      expect(await work.save(read: (_) async => bytes, name: 'late'), isFalse);
      await tester.pump();
      expect(find.text('Closing...'), findsOneWidget);
      expect(work.isBusy, isTrue);
      expect(exits, 0);
      earlierExit.complete();
      await tester.pump();
      expect(exits, 0);
      expect(work.isBusy, isTrue);
      reading.complete(bytes);
      await tester.pumpAndSettle();
      expect(await saving, isFalse);
      expect(deliveries, 0);
      expect(exits, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('window waits for an already started platform save', (
    tester,
  ) async {
    final platform = Completer<bool>();
    var entered = false;
    var exits = 0;
    final work = ImageSaveWork(
      deliver: (_, _, _) {
        entered = true;
        return platform.future;
      },
      onError: (error, _) => fail('$error'),
    );
    final content = ValueNotifier<Widget>(
      ImageSaveBinding(work: work, child: const Text('Owner')),
    );
    addTearDown(content.dispose);
    await mount(tester, content, onExit: () => exits++);
    final saving = work.save(read: (_) async => bytes, name: 'original');
    await tester.pump();
    expect(entered, isTrue);
    close(tester);
    await tester.pump(const Duration(milliseconds: 150));
    expect(exits, 0);
    expect(work.isBusy, isTrue);
    platform.complete(true);
    await tester.pumpAndSettle();
    expect(await saving, isTrue);
    expect(exits, 1);
    await tester.pumpWidget(const SizedBox());
  });

  for (final inPlatform in [false, true]) {
    testWidgets(
      'forced unmount hands pending work to real window; platform=$inPlatform',
      (tester) async {
        final reading = Completer<Uint8List>();
        final platform = Completer<bool>();
        var deliveries = 0;
        var exits = 0;
        final work = ImageSaveWork(
          deliver: (_, _, _) {
            deliveries++;
            return platform.future;
          },
          onError: (error, _) => fail('$error'),
        );
        final content = ValueNotifier<Widget>(
          ImageSaveBinding(work: work, child: const Text('Owner')),
        );
        addTearDown(content.dispose);
        await mount(tester, content, onExit: () => exits++);
        final saving = work.save(read: (_) => reading.future, name: 'original');
        if (inPlatform) reading.complete(bytes);
        await tester.pump();
        expect(deliveries, inPlatform ? 1 : 0);
        content.value = const Text('Replacement');
        await tester.pump();
        expect(find.byType(ImageSaveBinding), findsNothing);
        close(tester);
        await tester.pump();
        expect(exits, 0);
        expect(
          await work.save(read: (_) async => bytes, name: 'late'),
          isFalse,
        );
        if (inPlatform) {
          platform.complete(true);
        } else {
          reading.complete(bytes);
        }
        await tester.pumpAndSettle();
        expect(await saving, inPlatform);
        expect(deliveries, inPlatform ? 1 : 0);
        expect(exits, 1);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'a later exit failure releases the mounted save owner for retry',
    (tester) async {
      final content = ValueNotifier<Widget>(const Text('Before owner'));
      addTearDown(content.dispose);
      var exits = 0;
      var shouldFail = true;
      var deliveries = 0;
      final frame = await mount(tester, content, onExit: () => exits++);
      frame.addExitTask(() async {
        if (shouldFail) throw StateError('later exit failed');
      });
      final work = ImageSaveWork(
        deliver: (_, _, _) async {
          deliveries++;
          return true;
        },
        onError: (error, _) => fail('$error'),
      );
      content.value = ImageSaveBinding(work: work, child: const Text('Owner'));
      await tester.pump();
      close(tester);
      await tester.pump();
      expect(tester.takeException(), isA<StateError>());
      expect(exits, 0);
      expect(
        await work.save(read: (_) async => bytes, name: 'recovered'),
        isTrue,
      );
      expect(deliveries, 1);
      shouldFail = false;
      close(tester);
      await tester.pumpAndSettle();
      expect(exits, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final coverRoute in [false, true]) {
    testWidgets(
      'maybePop joins original read without popping a newer route; cover=$coverRoute',
      (tester) async {
        final navigator = GlobalKey<NavigatorState>();
        final reading = Completer<Uint8List>();
        final work = ImageSaveWork(
          deliver: (_, _, _) async => true,
          onError: (error, _) => fail('$error'),
        );
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            home: const Scaffold(body: Text('Home')),
          ),
        );
        navigator.currentState!.push<void>(
          MaterialPageRoute(
            builder: (_) => ImageSaveBinding(
              work: work,
              child: const Scaffold(body: Text('Saving route')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final saving = work.save(read: (_) => reading.future, name: 'original');
        await tester.pump();
        expect(await navigator.currentState!.maybePop(), isTrue);
        await tester.pump();
        expect(find.text('Saving route'), findsOneWidget);
        expect(work.isBusy, isTrue);
        if (coverRoute) {
          navigator.currentState!.push<void>(
            MaterialPageRoute(
              builder: (_) => const Scaffold(body: Text('New route')),
            ),
          );
          await tester.pumpAndSettle();
        }
        reading.complete(bytes);
        await tester.pumpAndSettle();
        expect(await saving, isFalse);
        if (coverRoute) {
          expect(find.text('New route'), findsOneWidget);
          navigator.currentState!.pop();
          await tester.pumpAndSettle();
          expect(find.text('Saving route'), findsOneWidget);
          expect(
            await work.save(read: (_) async => bytes, name: 'resumed'),
            isTrue,
          );
          await tester.pump();
          await navigator.currentState!.maybePop();
          await tester.pumpAndSettle();
        }
        expect(find.text('Home'), findsOneWidget);
        expect(find.text('Saving route'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'replacing work during window preparation freezes and joins both owners',
    (tester) async {
      final oldRead = Completer<Uint8List>();
      final newRead = Completer<Uint8List>();
      var exits = 0;
      var deliveries = 0;
      ImageSaveWork owner() => ImageSaveWork(
        deliver: (_, _, _) async {
          deliveries++;
          return true;
        },
        onError: (error, _) => fail('$error'),
      );
      final oldWork = owner();
      final newWork = owner();
      final content = ValueNotifier<Widget>(
        ImageSaveBinding(work: oldWork, child: const Text('Old owner')),
      );
      addTearDown(content.dispose);
      await mount(tester, content, onExit: () => exits++);
      final oldSaving = oldWork.save(read: (_) => oldRead.future, name: 'old');
      // Incoming owners can already have accepted work before being installed.
      final newSaving = newWork.save(read: (_) => newRead.future, name: 'new');
      close(tester);
      await tester.pump();
      content.value = ImageSaveBinding(
        work: newWork,
        child: const Text('New owner'),
      );
      await tester.pump();
      final lateAccepted = await newWork.save(
        read: (_) async => bytes,
        name: 'late',
      );
      oldRead.complete(bytes);
      await tester.pump();
      await tester.pump();
      final exitedBeforeIncomingRead = exits;
      newRead.complete(bytes);
      await tester.pumpAndSettle();
      final oldResult = await oldSaving;
      final newResult = await newSaving;
      await tester.pumpWidget(const SizedBox());
      expect(lateAccepted, isFalse);
      expect(exitedBeforeIncomingRead, 0);
      expect(oldResult, isFalse);
      expect(newResult, isFalse);
      expect(deliveries, 0);
      expect(exits, 1);
    },
  );

  testWidgets(
    'reparenting a preparing binding releases only its old window holds',
    (tester) async {
      final attachment = ValueNotifier<int>(-1);
      addTearDown(attachment.dispose);
      final bindingKey = GlobalKey();
      const firstFrameKey = Key('first frame');
      const secondFrameKey = Key('second frame');
      final frames = <int, WindowFrameController>{};
      final originalRead = Completer<Uint8List>();
      final laterFailure = Completer<void>();
      final platform = Completer<bool>();
      var firstExits = 0;
      var secondExits = 0;
      var platformEntered = false;
      final work = ImageSaveWork(
        deliver: (_, _, _) {
          platformEntered = true;
          return platform.future;
        },
        onError: (error, _) => fail('$error'),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<int>(
            valueListenable: attachment,
            builder: (_, position, _) => Row(
              children: [
                for (var index = 0; index < 2; index++)
                  Expanded(
                    child: WindowFrame(
                      Builder(
                        builder: (context) {
                          frames[index] = WindowFrame.of(context);
                          return Scaffold(
                            body: position == index
                                ? ImageSaveBinding(
                                    key: bindingKey,
                                    work: work,
                                    child: const Text('Moving owner'),
                                  )
                                : Text('Empty frame $index'),
                          );
                        },
                      ),
                      key: index == 0 ? firstFrameKey : secondFrameKey,
                      onExit: () => index == 0 ? firstExits++ : secondExits++,
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      frames[0]!.addExitTask(() async {
        await laterFailure.future;
        throw StateError('old frame later exit failed');
      });
      attachment.value = 0;
      await tester.pump();
      final oldState = bindingKey.currentState;
      final original = work.save(
        read: (_) => originalRead.future,
        name: 'original',
      );
      (tester.state(find.byKey(firstFrameKey)) as WindowListener)
          .onWindowClose();
      await tester.pump();
      attachment.value = 1;
      await tester.pump();
      expect(bindingKey.currentState, same(oldState));
      originalRead.complete(bytes);
      await tester.pump();
      laterFailure.complete();
      await tester.pump();
      expect(tester.takeException(), isA<StateError>());
      expect(await original, isFalse);
      // The old preparation finishing and failing must not retain or install
      // holds in the new frame, nor let it reuse the old preparation Future.
      final saving = work.save(read: (_) async => bytes, name: 'new frame');
      await tester.pump();
      final resumed = platformEntered;
      (tester.state(find.byKey(secondFrameKey)) as WindowListener)
          .onWindowClose();
      await tester.pump();
      final exitedBeforePlatform = secondExits;
      platform.complete(true);
      await tester.pumpAndSettle();
      final saved = await saving;
      await tester.pumpWidget(const SizedBox());
      expect(resumed, isTrue);
      expect(exitedBeforePlatform, 0);
      expect(saved, isTrue);
      expect(firstExits, 0);
      expect(secondExits, 1);
    },
  );

  testWidgets(
    'page return cannot pop through window freeze and recovers after close failure',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      final read = Completer<Uint8List>();
      final failure = Completer<void>();
      late WindowFrameController frame;
      var exits = 0;
      final work = ImageSaveWork(
        deliver: (_, _, _) async => true,
        onError: (error, _) => fail('$error'),
      );
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          builder: (_, child) => WindowFrame(child!, onExit: () => exits++),
          home: Builder(
            builder: (context) {
              frame = WindowFrame.of(context);
              return const Scaffold(body: Text('Home'));
            },
          ),
        ),
      );
      frame.addExitTask(() async {
        await failure.future;
        throw StateError('close after page return failed');
      });
      navigator.currentState!.push<void>(
        MaterialPageRoute(
          builder: (_) => ImageSaveBinding(
            work: work,
            child: const Scaffold(body: Text('Saving route')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final saving = work.save(read: (_) => read.future, name: 'original');
      await tester.pump();
      await navigator.currentState!.maybePop();
      await tester.pump();
      close(tester);
      await tester.pump();
      read.complete(bytes);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      final stayedDuringClose = find.text('Saving route').evaluate().isNotEmpty;
      failure.complete();
      await tester.pump();
      expect(tester.takeException(), isA<StateError>());
      expect(await saving, isFalse);
      final recovered = await work.save(
        read: (_) async => bytes,
        name: 'recovered',
      );
      await tester.pumpWidget(const SizedBox());
      expect(stayedDuringClose, isTrue);
      expect(recovered, isTrue);
      expect(exits, 0);
    },
  );

  testWidgets(
    'local history consuming a delayed pop releases the page exit hold',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      final read = Completer<Uint8List>();
      var historyRemoved = 0;
      final work = ImageSaveWork(
        deliver: (_, _, _) async => true,
        onError: (error, _) => fail('$error'),
      );
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('Home')),
        ),
      );
      final route = MaterialPageRoute<void>(
        builder: (_) => ImageSaveBinding(
          work: work,
          child: const Scaffold(body: Text('Saving route')),
        ),
      );
      navigator.currentState!.push(route);
      await tester.pumpAndSettle();
      route.addLocalHistoryEntry(
        LocalHistoryEntry(onRemove: () => historyRemoved++),
      );
      final saving = work.save(read: (_) => read.future, name: 'original');
      await tester.pump();
      await navigator.currentState!.maybePop();
      await tester.pump();
      expect(historyRemoved, 0);
      read.complete(bytes);
      await tester.pumpAndSettle();
      expect(await saving, isFalse);
      expect(historyRemoved, 1);
      expect(find.text('Saving route'), findsOneWidget);
      expect(
        await work.save(read: (_) async => bytes, name: 'resumed'),
        isTrue,
      );
      await tester.pump();
      await navigator.currentState!.maybePop();
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
