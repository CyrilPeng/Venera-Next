import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:lodepng_flutter/lodepng_flutter.dart' as lodepng;

class Image {
  final Uint32List _data;

  final int width;

  final int height;

  Image(this._data, this.width, this.height) {
    if (_data.length != width * height) {
      throw ArgumentError(
        'Invalid argument: data length must be equal to width * height.',
      );
    }
  }

  Image.empty(this.width, this.height) : _data = Uint32List(width * height);

  static Future<Image> decodeImage(
    Uint8List data, {
    Future<ui.Codec> Function(Uint8List)? instantiateCodec,
  }) async {
    ui.Codec? codec;
    ui.Image? decoded;
    Image? result;
    Object? failure;
    StackTrace? failureStack;
    final cleanup = <ImageProcessingResourceFailure>[];
    try {
      codec = await (instantiateCodec ?? ui.instantiateImageCodec)(data);
      decoded = (await codec.getNextFrame()).image;
      final info = await decoded.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      if (info == null) throw Exception('Failed to decode image');
      result = Image(
        info.buffer.asUint32List(info.offsetInBytes, info.lengthInBytes ~/ 4),
        decoded.width,
        decoded.height,
      );
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
    } finally {
      if (decoded != null) {
        _releaseImageResource('decoded image', decoded.dispose, cleanup);
      }
      if (codec != null) {
        _releaseImageResource('image codec', codec.dispose, cleanup);
      }
    }
    _throwImageProcessingFailure(failure, failureStack, cleanup);
    return result!;
  }

  Color getPixelAtIndex(int index) {
    if (index < 0 || index >= _data.length) {
      throw ArgumentError(
        'Invalid argument: index must be in the range of [0, ${_data.length}).',
      );
    }
    return Color.fromValue(_data[index]);
  }

  Image copyRange(int x, int y, int width, int height) {
    if (width + x > this.width) {
      throw ArgumentError(
        '''
        Invalid argument: x + width must be less than or equal to the image width.
        x: $x, width: $width, image width: ${this.width}
      '''
            .trim(),
      );
    }
    if (height + y > this.height) {
      throw ArgumentError(
        '''
        Invalid argument: y + height must be less than or equal to the image height.
        y: $y, height: $height, image height: ${this.height}
      '''
            .trim(),
      );
    }
    var data = Uint32List(width * height);
    for (var j = 0; j < height; j++) {
      for (var i = 0; i < width; i++) {
        data[j * width + i] = _data[(j + y) * this.width + i + x];
      }
    }
    return Image(data, width, height);
  }

  void fillImageAt(int x, int y, Image image) {
    if (x + image.width > width) {
      throw ArgumentError(
        '''
        Invalid argument: x + image width must be less than or equal to the image width.
        x: $x, image width: ${image.width}, image width: $width
      '''
            .trim(),
      );
    }
    if (y + image.height > height) {
      throw ArgumentError(
        '''
        Invalid argument: y + image height must be less than or equal to the image height.
        y: $y, image height: ${image.height}, image height: $height
      '''
            .trim(),
      );
    }
    for (var j = 0; j < image.height && (j + y) < height; j++) {
      for (var i = 0; i < image.width && (i + x) < width; i++) {
        _data[(j + y) * width + i + x] = image._data[j * image.width + i];
      }
    }
  }

  void fillImageRangeAt(
    int x,
    int y,
    Image image,
    int srcX,
    int srcY,
    int width,
    int height,
  ) {
    if (x + width > this.width) {
      throw ArgumentError(
        '''
        Invalid argument: x + width must be less than or equal to the image width.
        x: $x, width: $width, image width: ${this.width}
      '''
            .trim(),
      );
    }
    if (y + height > this.height) {
      throw ArgumentError(
        '''
        Invalid argument: y + height must be less than or equal to the image height.
        y: $y, height: $height, image height: ${this.height}
      '''
            .trim(),
      );
    }
    if (srcX + width > image.width) {
      throw ArgumentError(
        '''
        Invalid argument: srcX + width must be less than or equal to the image width.
        srcX: $srcX, width: $width, image width: ${image.width}
      '''
            .trim(),
      );
    }
    if (srcY + height > image.height) {
      throw ArgumentError(
        '''
        Invalid argument: srcY + height must be less than or equal to the image height.
        srcY: $srcY, height: $height, image height: ${image.height}
      '''
            .trim(),
      );
    }
    for (var j = 0; j < height; j++) {
      for (var i = 0; i < width; i++) {
        _data[(j + y) * this.width + i + x] =
            image._data[(j + srcY) * image.width + i + srcX];
      }
    }
  }

  Image copyAndRotate90() {
    var data = Uint32List(width * height);
    for (var j = 0; j < height; j++) {
      for (var i = 0; i < width; i++) {
        data[i * height + height - j - 1] = _data[j * width + i];
      }
    }
    return Image(data, height, width);
  }

  Uint8List encodePng() {
    var data = lodepng.encodePngToPointer(
      lodepng.Image(_data.buffer.asUint8List(), width, height),
    );
    return Pointer<Uint8>.fromAddress(
      data.address,
    ).asTypedList(data.length, finalizer: lodepng.ByteBuffer.finalizer);
  }
}

class Color {
  final int value;

  Color(int r, int g, int b, [int a = 255])
    : value = (a << 24) | (r << 16) | (g << 8) | b;

  Color.fromValue(this.value);

  int get r => value & 0xFF;

  int get g => (value >> 8) & 0xFF;

  int get b => (value >> 16) & 0xFF;

  int get a => (value >> 24) & 0xFF;
}

class _ImageScriptBridge {
  var images = <int, Image>{};

  int _key = 0;

  int setImage(Image image) {
    var key = _key++;
    images[key] = image;
    return key;
  }

  Object? _messageReceiver(dynamic message) {
    if (message is! Map) return null;
    var method = message['method'];
    if (method == 'image') {
      switch (message['function']) {
        case 'copyRange':
          var key = message['key'];
          var image = images[key];
          if (image == null) return null;
          var x = message['x'];
          var y = message['y'];
          var width = message['width'];
          var height = message['height'];
          var newImage = image.copyRange(x, y, width, height);
          return setImage(newImage);
        case 'copyAndRotate90':
          var key = message['key'];
          var image = images[key];
          if (image == null) return null;
          var newImage = image.copyAndRotate90();
          return setImage(newImage);
        case 'fillImageAt':
          var key = message['key'];
          var image = images[key];
          if (image == null) return null;
          var x = message['x'];
          var y = message['y'];
          var key2 = message['image'];
          var image2 = images[key2];
          if (image2 == null) return null;
          image.fillImageAt(x, y, image2);
          return null;
        case 'fillImageRangeAt':
          var key = message['key'];
          var image = images[key];
          if (image == null) return null;
          var x = message['x'];
          var y = message['y'];
          var key2 = message['image'];
          var image2 = images[key2];
          if (image2 == null) return null;
          var srcX = message['srcX'];
          var srcY = message['srcY'];
          var width = message['width'];
          var height = message['height'];
          image.fillImageRangeAt(x, y, image2, srcX, srcY, width, height);
          return null;
        case 'getWidth':
          var key = message['key'];
          var image = images[key];
          if (image == null) return null;
          return image.width;
        case 'getHeight':
          var key = message['key'];
          var image = images[key];
          if (image == null) return null;
          return image.height;
        case 'emptyImage':
          var width = message['width'];
          var height = message['height'];
          var newImage = Image.empty(width, height);
          return setImage(newImage);
      }
    }
    return null;
  }
}

final _imageScriptSlots = _AsyncSemaphore(4);

@visibleForTesting
Future<T> debugRunWithImageScriptSlot<T>(Future<T> Function() task) {
  return _imageScriptSlots.run(task);
}

Future<Uint8List> modifyImageWithScript(Uint8List data, String script) async {
  return _imageScriptSlots.run(() async {
    final image = await Image.decodeImage(data);
    final initJs = await rootBundle.loadString('assets/init.js');
    return Isolate.run(
      () => runImageScript(image, script, initializationScript: initJs),
    );
  });
}

typedef ImageProcessingResourceFailure = ({
  String resource,
  Object error,
  StackTrace stack,
});

class ImageProcessingFailure implements Exception {
  ImageProcessingFailure({
    required this.cause,
    required this.causeStack,
    required Iterable<ImageProcessingResourceFailure> failures,
  }) : failures = List.unmodifiable(failures);

  final Object? cause;
  final StackTrace? causeStack;
  final List<ImageProcessingResourceFailure> failures;

  @override
  String toString() =>
      'Image processing failed: ${cause ?? 'resource cleanup'}; '
      '${failures.map((failure) => '${failure.resource}: ${failure.error}').join('; ')}';
}

void _releaseImageResource(
  String resource,
  void Function() release,
  List<ImageProcessingResourceFailure> failures,
) {
  try {
    release();
  } catch (error, stack) {
    failures.add((resource: resource, error: error, stack: stack));
  }
}

void _throwImageProcessingFailure(
  Object? cause,
  StackTrace? causeStack,
  List<ImageProcessingResourceFailure> failures,
) {
  if (failures.isNotEmpty) {
    throw ImageProcessingFailure(
      cause: cause,
      causeStack: causeStack,
      failures: failures,
    );
  }
  if (cause != null) Error.throwWithStackTrace(cause, causeStack!);
}

/// One synchronous image-script task owns its runtime and all returned values.
/// Dispatch is joined after closing the port, including on partial startup.
Future<Uint8List> runImageScript(
  Image image,
  String script, {
  required String initializationScript,
  FlutterQjs Function()? createEngine,
  Uint8List Function(Image)? encodeImage,
}) async {
  FlutterQjs? engine;
  Future<void>? dispatch;
  final bridge = _ImageScriptBridge();
  final values = <Object?>[];
  final cleanup = <ImageProcessingResourceFailure>[];
  Object? failure;
  StackTrace? failureStack;
  Uint8List? result;
  dynamic evaluate(String code, [String? name]) {
    final value = engine!.evaluate(code, name: name);
    values.add(value);
    return value;
  }

  try {
    engine = (createEngine ?? FlutterQjs.new)();
    dispatch = engine.dispatch();
    dispatch.ignore();
    final setGlobal = evaluate('(key, value) => { this[key] = value; }');
    values.add(
      (setGlobal as JSInvokable)(['sendMessage', bridge._messageReceiver]),
    );
    // The protocol is synchronous; unused statement results stay inside JS.
    evaluate('$initializationScript\n;void 0;', '<init>');
    evaluate('$script\n;void 0;');
    final key = bridge.setImage(image);
    final resultKey = evaluate('''
      (() => {
        const image = new Image($key);
        const result = modifyImage(image);
        return result.key;
      })();
    ''');
    final modified = resultKey is int ? bridge.images[resultKey] : null;
    if (modified == null) {
      throw StateError('modifyImage must return an Image synchronously');
    }
    result = Uint8List.fromList(
      (encodeImage ?? (image) => image.encodePng())(modified),
    );
  } catch (error, stack) {
    // JavaScript may throw a graph containing native references as well.
    values.add(error);
    failure = error;
    failureStack = stack;
  } finally {
    final visited = Set<Object>.identity();
    void releaseValue(Object? value) {
      if (value == null || !visited.add(value)) return;
      if (value is JSRef) {
        _releaseImageResource('JS result', value.free, cleanup);
      } else if (value is Map) {
        for (final entry in value.entries) {
          releaseValue(entry.key);
          releaseValue(entry.value);
        }
      } else if (value is List && value is! TypedData) {
        for (final entry in value) {
          releaseValue(entry);
        }
      }
    }

    for (final value in values) {
      _releaseImageResource(
        'JS result graph',
        () => releaseValue(value),
        cleanup,
      );
    }
    if (engine != null) {
      _releaseImageResource('JS runtime', () => engine!.close(), cleanup);
      _releaseImageResource(
        'JS runtime port',
        () => engine!.port.close(),
        cleanup,
      );
    }
    if (dispatch != null) {
      try {
        await dispatch;
      } catch (error, stack) {
        cleanup.add((resource: 'JS dispatch', error: error, stack: stack));
      }
    }
    bridge.images.clear();
  }
  _throwImageProcessingFailure(failure, failureStack, cleanup);
  return result!;
}

class _AsyncSemaphore {
  final int maxConcurrent;

  int _active = 0;

  final _waiters = Queue<Completer<void>>();

  _AsyncSemaphore(this.maxConcurrent);

  Future<T> run<T>(Future<T> Function() task) async {
    await _acquire();
    try {
      return await task();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() {
    if (_active < maxConcurrent) {
      _active++;
      return Future.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
      return;
    }
    _active--;
  }
}
