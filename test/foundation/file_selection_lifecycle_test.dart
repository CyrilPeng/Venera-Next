import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/file_interaction.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('venera/select_file');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const receipt = {'path': 'owned/book.pdf', 'token': 'owner'};
  FileSelection selected() =>
      FileSelection.androidDocument(uri: 'content://book', name: 'book.pdf');
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('concurrent preparation shares one native copy', () async {
    final gate = Completer<Map<String, Object>>();
    var prepares = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'prepareFile') return null;
      prepares++;
      return gate.future;
    });
    final selection = selected();
    final first = selection.prepare();
    final second = selection.prepare();
    expect(second, same(first));
    gate.complete({...receipt, 'temporary': true});
    await Future.wait([first, second]);
    expect(prepares, 1);
    await selection.dispose();
  });

  test(
    'close waits preparation and releases late copy without delivery',
    () async {
      final gate = Completer<Map<String, Object>>();
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'prepareFile' ? gate.future : null;
      });
      final selection = selected();
      final prepared = expectLater(selection.prepare(), throwsStateError);
      var closed = false;
      final closing = selection.dispose().then((_) => closed = true);
      await pumpEventQueue();
      expect(closed, isFalse);
      gate.complete({...receipt, 'temporary': true});
      await Future.wait([prepared, closing]);
      expect(calls.map((call) => call.method), ['prepareFile', 'releaseFile']);
      expect(calls.last.arguments, receipt);
    },
  );

  test('close retains file through an already started consumer', () async {
    final started = Completer<void>();
    final consumed = Completer<void>();
    var releases = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'prepareFile') return {...receipt, 'temporary': true};
      releases++;
      return null;
    });
    final selection = selected();
    final use = selection.withFile((_) async {
      started.complete();
      await consumed.future;
    });
    await started.future;
    final closing = selection.dispose();
    await pumpEventQueue();
    expect(releases, 0);
    await expectLater(selection.withFile((_) async {}), throwsStateError);
    consumed.complete();
    await Future.wait([use, closing]);
    expect(releases, 1);
  });

  test('close before consumer starts rejects it without preparing', () async {
    var prepares = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      prepares++;
      return null;
    });
    final selection = selected();
    var entered = false;
    final use = expectLater(
      selection.withFile((_) async {
        entered = true;
      }),
      throwsStateError,
    );
    await selection.dispose();
    await use;
    expect(entered, isFalse);
    expect(prepares, 0);
  });

  test(
    'failed release retries the original receipt without preparing again',
    () async {
      final calls = <MethodCall>[];
      var fail = true;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'prepareFile') {
          return {...receipt, 'temporary': true};
        }
        if (fail) throw PlatformException(code: 'release');
        return null;
      });
      final selection = selected();
      await selection.prepare();
      await expectLater(selection.dispose(), throwsA(isA<PlatformException>()));
      fail = false;
      await selection.dispose();
      expect(calls.map((call) => call.method), [
        'prepareFile',
        'releaseFile',
        'releaseFile',
      ]);
      expect(calls.last.arguments, receipt);
    },
  );

  test(
    'copy and cleanup errors preserve receipt and both causes for retry',
    () async {
      var fail = true;
      var copies = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'prepareFile') {
          copies++;
          throw PlatformException(code: 'copy', details: receipt);
        }
        expect(call.arguments, receipt);
        if (fail) throw PlatformException(code: 'release');
        return null;
      });
      final selection = selected();
      await expectLater(
        withSelectedFile(selection, (file) => file.readAsBytes()),
        throwsA(
          isA<FileSelectionCleanupFailure>()
              .having(
                (failure) => (failure.operationError as PlatformException).code,
                'copy',
                'copy',
              )
              .having(
                (failure) => (failure.cleanupError as PlatformException).code,
                'release',
                'release',
              )
              .having(
                (failure) => failure.selection,
                'selection',
                same(selection),
              ),
        ),
      );
      fail = false;
      await selection.dispose();
      expect(copies, 1);
    },
  );

  test(
    'failed preparation without receipt can retry and never invents deletion authority',
    () async {
      var attempts = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'prepareFile');
        if (++attempts == 1) throw PlatformException(code: 'copy');
        return {'path': 'borrowed.pdf', 'temporary': false};
      });
      final selection = selected();
      await expectLater(selection.prepare(), throwsA(isA<PlatformException>()));
      expect((await selection.prepare()).path, 'borrowed.pdf');
      await selection.dispose();
      expect(attempts, 2);
    },
  );
}
