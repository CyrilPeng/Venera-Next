import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/clipboard_image.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('venera/clipboard');
  // Two pixels: opaque red and half-transparent green.
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAAEUlEQVR4nGP4z8Dwn+E/QwMAEHkDfiHA/Y0AAAAASUVORK5CYII=',
  );

  group(
    'desktop clipboard image ownership',
    () {
      late ui.ImageEventCallback? previousOnCreate;
      late ui.ImageEventCallback? previousOnDispose;
      late List<ui.Image> created;
      late List<ui.Image> disposed;

      setUp(() {
        created = [];
        disposed = [];
        previousOnCreate = ui.Image.onCreate;
        previousOnDispose = ui.Image.onDispose;
        ui.Image.onCreate = (image) {
          created.add(image);
          previousOnCreate?.call(image);
        };
        ui.Image.onDispose = (image) {
          disposed.add(image);
          previousOnDispose?.call(image);
        };
      });

      tearDown(() {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
        ui.Image.onCreate = previousOnCreate;
        ui.Image.onDispose = previousOnDispose;
        for (final image in created) {
          if (!image.debugDisposed) image.dispose();
        }
      });

      test(
        'copies raw RGBA and releases each native image after completion',
        () async {
          final calls = <MethodCall>[];
          binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
            call,
          ) async {
            calls.add(call);
            return null;
          });

          for (var attempt = 0; attempt < 3; attempt++) {
            await writeImageToClipboard(png);
            expect(created, hasLength(attempt + 1));
            expect(disposed, orderedEquals(created));
            expect(created.every((image) => image.debugDisposed), isTrue);
          }

          for (final call in calls) {
            expect(call.method, 'writeImageToClipboard');
            expect(call.arguments, {
              'width': 2,
              'height': 1,
              'data': Uint8List.fromList([255, 0, 0, 255, 0, 128, 0, 128]),
            });
          }
        },
      );

      test(
        'keeps the image alive until an asynchronous platform call finishes',
        () async {
          final invoked = Completer<void>();
          final finish = Completer<void>();
          binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
            call,
          ) async {
            invoked.complete();
            await finish.future;
            return null;
          });

          final copy = writeImageToClipboard(png);
          await invoked.future;
          expect(created, hasLength(1));
          expect(created.single.debugDisposed, isFalse);
          expect(disposed, isEmpty);
          finish.complete();
          await copy;

          expect(disposed, orderedEquals(created));
          expect(created.single.debugDisposed, isTrue);
        },
      );

      test(
        'releases native images after platform failures and can retry',
        () async {
          var fail = true;
          binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
            call,
          ) async {
            if (fail) {
              throw PlatformException(
                code: 'clipboard_unavailable',
                message: 'busy',
              );
            }
            return null;
          });

          for (var attempt = 0; attempt < 3; attempt++) {
            await expectLater(
              writeImageToClipboard(png),
              throwsA(
                isA<PlatformException>()
                    .having(
                      (error) => error.code,
                      'code',
                      'clipboard_unavailable',
                    )
                    .having((error) => error.message, 'message', 'busy'),
              ),
            );
            expect(created, hasLength(attempt + 1));
            expect(disposed, orderedEquals(created));
            expect(created.every((image) => image.debugDisposed), isTrue);
          }

          fail = false;
          await writeImageToClipboard(png);
          expect(created, hasLength(4));
          expect(disposed, orderedEquals(created));
          expect(created.last.debugDisposed, isTrue);
        },
      );

      test(
        'rejects invalid encoded bytes before calling the platform',
        () async {
          var calls = 0;
          binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
            call,
          ) async {
            calls++;
            return null;
          });

          await expectLater(
            writeImageToClipboard(Uint8List.fromList([1, 2, 3])),
            throwsA(anything),
          );
          expect(calls, 0);
          expect(created, isEmpty);

          await writeImageToClipboard(png);
          expect(calls, 1);
          expect(created, hasLength(1));
          expect(disposed, orderedEquals(created));
          expect(created.single.debugDisposed, isTrue);
        },
      );

      test(
        'rejects frame decode failures before calling the platform',
        () async {
          // Keep a readable PNG header but corrupt the compressed pixel stream.
          final corruptPng = Uint8List.fromList(png)..[41] = 0;
          final codec = await ui.instantiateImageCodec(corruptPng);
          try {
            // This fixture must reach getNextFrame, after allocating a codec.
            await expectLater(codec.getNextFrame(), throwsA(isA<Exception>()));
          } finally {
            codec.dispose();
          }

          var calls = 0;
          binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
            call,
          ) async {
            calls++;
            return null;
          });
          await expectLater(
            writeImageToClipboard(corruptPng),
            throwsA(isA<Exception>()),
          );
          expect(calls, 0);
          expect(created, isEmpty);

          await writeImageToClipboard(png);
          expect(calls, 1);
          expect(created, hasLength(1));
          expect(disposed, orderedEquals(created));
          expect(created.single.debugDisposed, isTrue);
        },
      );
    },
    skip: !Platform.isWindows && !Platform.isLinux,
  );
}
