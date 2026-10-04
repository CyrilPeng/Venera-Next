import 'dart:io';
import 'dart:ui';

import 'package:flutter/services.dart';

Future<void> writeImageToClipboard(Uint8List imageBytes) async {
  const channel = MethodChannel("venera/clipboard");
  if (Platform.isWindows || Platform.isLinux) {
    final codec = await instantiateImageCodec(imageBytes);
    Image? image;
    Object? failure;
    StackTrace? failureStack;
    try {
      image = (await codec.getNextFrame()).image;
      final data = await image.toByteData(format: ImageByteFormat.rawRgba);
      await channel.invokeMethod("writeImageToClipboard", {
        "width": image.width,
        "height": image.height,
        "data": Uint8List.sublistView(data!),
      });
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
    } finally {
      // Release both owners even when decoding or the platform call fails.
      // Cleanup failures must not replace the original clipboard error.
      try {
        image?.dispose();
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
      try {
        codec.dispose();
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }
    if (failure != null) {
      Error.throwWithStackTrace(failure, failureStack!);
    }
  } else if (Platform.isMacOS) {
    await channel.invokeMethod("writeImageToClipboard", {"data": imageBytes});
  } else {
    throw UnsupportedError("Clipboard image is not supported on this platform");
  }
}
