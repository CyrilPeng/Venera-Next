import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart' as plugin;
// Exercise the real serializer supplied by the existing share_plus dependency.
// ignore: depend_on_referenced_packages
import 'package:share_plus_platform_interface/method_channel/method_channel_share.dart';
// ignore: depend_on_referenced_packages
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/file_interaction.dart' as interaction;
import 'package:venera_next/foundation/share_file_operation.dart';
import 'package:venera_next/foundation/image_work.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late SharePlatform previous;
  late Directory root;
  late String previousCache;
  final calls = <MethodCall>[];
  final replies = <Completer<String?>>[];
  setUpAll(() {
    previous = SharePlatform.instance;
    SharePlatform.instance = MethodChannelShare();
    App.cachePath = Directory.systemTemp.path;
  });
  tearDownAll(() => SharePlatform.instance = previous);
  setUp(() {
    root = Directory.systemTemp.createTempSync('share-adapter-');
    previousCache = App.cachePath;
    App.cachePath = root.path;
    calls.clear();
    replies.clear();
    messenger.setMockMethodCallHandler(MethodChannelShare.channel, (call) {
      calls.add(call);
      final reply = Completer<String?>();
      replies.add(reply);
      return reply.future;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(MethodChannelShare.channel, null);
    App.cachePath = previousCache;
    root.deleteSync(recursive: true);
  });
  Future<void> file(String name, int value, {Rect? origin}) =>
      interaction.Share.shareFile(
        data: Uint8List.fromList([value]),
        filename: name,
        mime: 'image/png',
        origin: origin,
      );
  File source(int index) =>
      File((calls[index].arguments['paths'] as List).single as String);

  test(
    'real serializer carries name, MIME and origin while Windows retains independent sources',
    () async {
      final old = File(p.join(root.path, '漫画.png'))..writeAsBytesSync([9]);
      var done = false;
      final first = file(
        '漫画.png',
        1,
        origin: const Rect.fromLTWH(12, 24, 90, 50),
      ).then((_) => done = true);
      await _until(() => calls.length == 1);
      expect(calls.single.method, 'share');
      final params = calls.single.arguments as Map;
      expect(params['title'], '漫画.png');
      expect(params['mimeTypes'], ['image/png']);
      expect(
        [
          params['originX'],
          params['originY'],
          params['originWidth'],
          params['originHeight'],
        ],
        [12.0, 24.0, 90.0, 50.0],
      );
      final firstSource = source(0);
      expect(p.basename(firstSource.path), '漫画.png');
      expect(
        p.dirname(p.dirname(firstSource.path)),
        p.join(root.path, 'shares'),
      );
      expect(firstSource.readAsBytesSync(), [1]);
      expect(done, isFalse);
      replies[0].complete('receiver');
      await first;
      expect(firstSource.readAsBytesSync(), [1]);
      final second = file('漫画.png', 2);
      await _until(() => calls.length == 2);
      final secondSource = source(1);
      expect(secondSource.path, isNot(firstSource.path));
      replies[1].complete(null);
      await second;
      expect(firstSource.readAsBytesSync(), [1]);
      expect(secondSource.readAsBytesSync(), [2]);
      expect(old.readAsBytesSync(), [9]);
    },
    skip: !Platform.isWindows,
  );

  test(
    'file and text share one queue and await original native Future',
    () async {
      final first = file('first.png', 1);
      final text = interaction.Share.shareText(
        'captured text',
        origin: const Rect.fromLTWH(1, 2, 3, 4),
      );
      final last = file('last.png', 2);
      await _until(() => calls.isNotEmpty);
      await pumpEventQueue();
      expect(calls, hasLength(1));
      expect(calls[0].arguments['title'], 'first.png');
      replies[0].complete('first');
      await first;
      await _until(() => calls.length == 2);
      expect(calls[1].arguments['text'], 'captured text');
      expect(calls[1].arguments['paths'], isNull);
      expect(calls[1].arguments['originWidth'], 3.0);
      replies[1].complete('text');
      await text;
      await _until(() => calls.length == 3);
      expect(calls[2].arguments['title'], 'last.png');
      replies[2].complete('last');
      await last;
    },
    skip: Platform.isLinux,
  );

  test('transport error retains original stack and queue continues', () async {
    final error = StateError('transport failed');
    final stack = StackTrace.fromString('original transport stack');
    messenger.setMockMessageHandler(
      MethodChannelShare.channel.name,
      (_) => Future.error(error, stack),
    );
    final failed = await _capture(interaction.Share.shareText('fails'));
    expect(failed.error, same(error));
    expect(failed.stack.toString(), stack.toString());
    messenger.setMockMethodCallHandler(MethodChannelShare.channel, (
      call,
    ) async {
      calls.add(call);
      return 'recovered';
    });
    await interaction.Share.shareText('works');
    expect(calls.single.arguments['text'], 'works');
  });

  test(
    'native error retains diagnostics and Windows source',
    () async {
      final captured = _capture(file('failed.png', 7));
      await _until(() => calls.length == 1);
      final retained = source(0);
      replies.single.completeError(
        PlatformException(
          code: 'native-failed',
          message: 'receiver unavailable',
          details: {'step': 'dispatch'},
        ),
      );
      final failure = (await captured).error as PlatformException;
      expect(failure.code, 'native-failed');
      expect(failure.details, {'step': 'dispatch'});
      expect(failure.message, 'receiver unavailable');
      expect(retained.readAsBytesSync(), [7]);
    },
    skip: !Platform.isWindows,
  );

  test(
    'Android source policy joins real channel then deletes only owned input',
    () async {
      final namespace = Directory(p.join(root.path, 'shares'))..createSync();
      final neighbour = File(p.join(namespace.path, 'neighbour.png'))
        ..writeAsBytesSync([9]);
      final operation = withShareFileSource(
        data: Uint8List.fromList([4]),
        filename: 'android.png',
        cacheDirectory: namespace,
        retainAfterDispatch: false,
        share: (source) => plugin.SharePlus.instance.share(
          plugin.ShareParams(
            files: [plugin.XFile(source.path, mimeType: 'image/png')],
          ),
        ),
      );
      await _until(() => calls.length == 1);
      final input = source(0);
      expect(input.readAsBytesSync(), [4]);
      replies.single.complete('copied to native cache');
      await operation;
      expect(input.existsSync(), isFalse);
      expect(neighbour.readAsBytesSync(), [9]);
      expect(namespace.listSync().map((entry) => entry.path), [neighbour.path]);
    },
  );

  for (final duringWrite in [false, true]) {
    test(
      'cancelled queued file never dispatches and removes only undispatched source; write=$duringWrite',
      () async {
        final owner = ImageWork();
        final task = owner.start()!;
        final first = file('first.png', 1);
        await _until(() => calls.length == 1);
        final retained = source(0);
        final gate = _WriteGate(p.join(root.path, 'shares'));
        var settled = false;
        final cancelled =
            _capture(
              IOOverrides.runWithIOOverrides(
                () => interaction.Share.shareFile(
                  data: Uint8List.fromList([2]),
                  filename: 'second.png',
                  mime: 'image/png',
                  checkStop: task.check,
                ),
                gate,
              ),
            ).then((failure) {
              settled = true;
              return failure;
            });
        if (!duringWrite) task.cancel();
        replies[0].complete('first acknowledged');
        await first;
        if (duringWrite) {
          await gate.entered.future;
          task.cancel();
          await pumpEventQueue();
          expect(settled, isFalse);
          expect(
            Directory(p.join(root.path, 'shares')).listSync(),
            hasLength(2),
          );
          gate.release.complete();
        }
        final failure = await cancelled;
        expect(failure.error, isA<ImageWorkTaskCancelled>());
        expect(calls, hasLength(1));
        expect(retained.readAsBytesSync(), [1]);
        expect(Directory(p.join(root.path, 'shares')).listSync(), hasLength(1));
        task.finish();
        await owner.dispose();
      },
      skip: Platform.isLinux,
    );
  }

  test(
    'file dispatch resolves resized origin after real staged write completes',
    () async {
      var origin = const Rect.fromLTWH(0, 0, 800, 600);
      final gate = _WriteGate(p.join(root.path, 'shares'));
      final sharing = IOOverrides.runWithIOOverrides(
        () => interaction.Share.shareFile(
          data: Uint8List.fromList([3]),
          filename: 'second.png',
          mime: 'image/png',
          resolveOrigin: () => origin,
        ),
        gate,
      );
      await gate.entered.future;
      origin = const Rect.fromLTWH(0, 0, 500, 400);
      gate.release.complete();
      await _until(() => calls.length == 1);
      expect(calls.single.arguments['originWidth'], 500.0);
      expect(calls.single.arguments['originHeight'], 400.0);
      replies.single.complete('shared');
      await sharing;
    },
    skip: Platform.isLinux,
  );

  test(
    'real Android adapter cleans input after native acknowledgement',
    () async {
      final sharing = file('android.png', 4);
      await _until(() => calls.length == 1);
      final input = source(0);
      expect(input.existsSync(), isTrue);
      replies.single.complete('native copy finished');
      await sharing;
      expect(input.existsSync(), isFalse);
    },
    skip: !Platform.isAndroid,
  );

  test(
    'Linux rejects file sharing without creating source or invoking plugin',
    () async {
      await expectLater(file('linux.png', 4), throwsUnsupportedError);
      expect(root.listSync(), isEmpty);
      expect(calls, isEmpty);
    },
    skip: !Platform.isLinux,
  );
}

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 400 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue);
}

Future<({Object error, StackTrace stack})> _capture(
  Future<void> operation,
) async {
  try {
    await operation;
  } catch (error, stack) {
    return (error: error, stack: stack);
  }
  throw TestFailure('Expected operation to fail');
}

final class _WriteGate extends IOOverrides {
  _WriteGate(this.directory);
  final String directory;
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  File createFile(String path) {
    final raw = super.createFile(path);
    return p.isWithin(directory, path) && p.basename(path) == 'second.png'
        ? _WaitingWrite(raw, entered, release.future)
        : raw;
  }
}

class _WaitingWrite implements File {
  _WaitingWrite(this.raw, this.entered, this.release);
  final File raw;
  final Completer<void> entered;
  final Future<void> release;
  @override
  String get path => raw.path;
  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async {
    entered.complete();
    await release;
    return raw.writeAsBytes(bytes, mode: mode, flush: flush);
  }

  @override
  Future<int> length() => raw.length();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
