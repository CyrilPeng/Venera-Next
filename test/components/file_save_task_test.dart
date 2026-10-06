import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/file_save_task.dart';
import 'package:venera_next/components/image_save_binding.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/file_interaction.dart' show overrideIO;
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/foundation/image_save_work.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/selection_operation.dart';

const _selector = MethodChannel('plugins.flutter.io/file_selector');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Directory cache;
  late BuildContext context;
  late SelectionTaskRegistry registry;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Widget app({bool window = false, Widget? child}) => MaterialApp(
    builder: (_, child) => SelectionTasksScope(
      registry: registry,
      child: window ? WindowFrame(child!, onExit: () {}) : child!,
    ),
    home: Builder(
      builder: (owner) {
        context = owner;
        return Scaffold(body: child);
      },
    ),
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('save-task-');
    cache = Directory('${root.path}/cache')..createSync();
    App.cachePath = cache.path;
    registry = SelectionTaskRegistry();
    final muted = Log.isMuted;
    Log.isMuted = true;
    addTearDown(() => Log.isMuted = muted);
    messenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (_) async => false,
    );
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(_selector, null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      null,
    );
    root.deleteSync(recursive: true);
  });

  testWidgets('completed image owner cannot release a failed save cleanup', (
    tester,
  ) async {
    final work = ImageSaveWork(
      deliver: (data, filename, checkStop) => saveFileForWindow(
        context,
        data: data,
        filename: filename,
        checkStop: checkStop,
      ),
      onError: (_, _) => fail('The save boundary reports cleanup failure'),
    );
    await tester.pumpWidget(
      app(
        child: ImageSaveBinding(work: work, child: const SizedBox()),
      ),
    );
    late File unknown;
    final destination = File('${root.path}/image.png');
    var dialogs = 0;
    messenger.setMockMethodCallHandler(_selector, (_) async {
      dialogs++;
      final owner = cache.listSync().whereType<Directory>().single;
      unknown = File('${owner.path}/unrelated')..writeAsStringSync('keep');
      return destination.path;
    });
    await tester.runAsync(() async {
      expect(
        await work.save(
          name: 'image',
          read: (_) async => Uint8List.fromList([4, 5]),
        ),
        isFalse,
      );
      expect(destination.readAsBytesSync(), [4, 5]);
      expect(work.isBusy, isFalse);
    });
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await expectLater(
        registry.closeAndWait(),
        throwsA(isA<SelectionCleanupFailure>()),
      );
      expect(unknown.readAsStringSync(), 'keep');
      destination.writeAsBytesSync([9]);
      unknown.deleteSync();
      await registry.closeAndWait();
      expect(destination.readAsBytesSync(), [9]);
      expect(cache.listSync(), isEmpty);
      expect(dialogs, 1);
    });
    expect(tester.takeException(), isNull);
  });

  for (final window in [false, true]) {
    testWidgets(
      'removed save host retains failed cleanup without repeating save; window=$window',
      (tester) async {
        await tester.pumpWidget(app(window: window));
        late Completer<void> entered;
        late Completer<String?> reply;
        var dialogs = 0;
        late File unknown;
        final destination = File('${root.path}/saved.png');
        messenger.setMockMethodCallHandler(_selector, (_) {
          dialogs++;
          final owner = cache.listSync().whereType<Directory>().single;
          unknown = File('${owner.path}/unrelated')..writeAsStringSync('keep');
          entered.complete();
          return reply.future;
        });
        late Future<bool> saving;
        await tester.runAsync(() async {
          entered = Completer<void>();
          reply = Completer<String?>();
          saving = overrideIO(
            () => saveFileForWindow(
              context,
              data: Uint8List.fromList([4, 5]),
              filename: 'saved.png',
            ),
          );
          await entered.future.timeout(const Duration(seconds: 10));
          reply.complete(destination.path);
          // Delivery succeeded; the unknown sibling makes ownership cleanup fail.
          expect(await saving, isFalse);
          expect(destination.readAsBytesSync(), [4, 5]);
        });
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await expectLater(
            registry.closeAndWait(),
            throwsA(isA<SelectionCleanupFailure>()),
          );
          expect(unknown.readAsStringSync(), 'keep');
          destination.writeAsBytesSync([8]);
          unknown.deleteSync();
          await registry.closeAndWait();
          expect(cache.listSync(), isEmpty);
          expect(destination.readAsBytesSync(), [8]);
          expect(dialogs, 1);
        });
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'removed page and closing host drain picker without writing late result',
    (tester) async {
      await tester.pumpWidget(app());
      late Completer<void> entered;
      late Completer<String?> reply;
      messenger.setMockMethodCallHandler(_selector, (_) {
        entered.complete();
        return reply.future;
      });
      late Future<bool> saving;
      await tester.runAsync(() async {
        entered = Completer<void>();
        reply = Completer<String?>();
        saving = saveFileForWindow(
          context,
          data: Uint8List.fromList([1]),
          filename: 'late.bin',
        );
        await entered.future.timeout(const Duration(seconds: 10));
      });
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        var closed = false;
        final closing = registry.closeAndWait().then((_) => closed = true);
        await pumpEventQueue();
        expect(closed, isFalse);
        expect(cache.listSync(), hasLength(1));
        reply.complete('${root.path}/late.bin');
        expect(await saving, isFalse);
        await closing;
        expect(File('${root.path}/late.bin').existsSync(), isFalse);
        expect(cache.listSync(), isEmpty);
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('image cancellation stays silent and does not open a picker', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    var dialogs = 0;
    messenger.setMockMethodCallHandler(_selector, (_) async {
      dialogs++;
      return null;
    });
    await tester.runAsync(() async {
      expect(
        await saveFileForWindow(
          context,
          data: Uint8List(0),
          filename: 'a.bin',
          checkStop: () => throw const ImageWorkTaskCancelled(),
        ),
        isFalse,
      );
      expect(cache.listSync(), isEmpty);
    });
    await tester.pump();
    expect(dialogs, 0);
    expect(find.text('Error'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
