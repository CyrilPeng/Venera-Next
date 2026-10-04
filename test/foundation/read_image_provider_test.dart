import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/image_provider/base_image_provider.dart';
import 'package:venera_next/foundation/image_provider/image_provider_lifecycle.dart';
import 'package:venera_next/foundation/image_provider/read_image.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/request_scope.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==',
);

class _ByteProvider extends BaseImageProvider<_ByteProvider> {
  _ByteProvider(this.read, {this.decoder});
  final Future<Uint8List> Function() read;
  final ImageDecoderCallback? decoder;
  int loads = 0;
  @override
  String get key => 'read-image-${identityHashCode(this)}';
  @override
  Future<_ByteProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  Future<Uint8List> load(chunkEvents, checkStop) {
    loads++;
    return read();
  }

  @override
  ImageStreamCompleter loadImage(
    _ByteProvider key,
    ImageDecoderCallback decode,
  ) => super.loadImage(key, decoder ?? decode);
}

class _Frame implements ui.FrameInfo {
  _Frame(this.image);
  @override
  final ui.Image image;
  @override
  Duration get duration => Duration.zero;
}

class _Codec implements ui.Codec {
  _Codec(this.frame);
  final Future<ui.FrameInfo> frame;
  int reads = 0;
  int disposals = 0;
  @override
  int get frameCount => 1;
  @override
  int get repetitionCount => 0;
  @override
  Future<ui.FrameInfo> getNextFrame() {
    reads++;
    return frame;
  }

  @override
  void dispose() => disposals++;
}

class _StreamCompleter extends ImageStreamCompleter {
  final added = <ImageStreamListener>[];
  void emit(ImageInfo info) => setImage(info);
  @override
  void addListener(ImageStreamListener listener) {
    added.add(listener);
    super.addListener(listener);
  }
}

class _Provider extends ImageProvider<String> {
  _Provider(this.completer, {this.keyFuture, String? key})
    : key = key ?? 'manual-read-image-${identityHashCode(completer)}';
  final _StreamCompleter completer;
  final Future<String>? keyFuture;
  final String key;
  int loads = 0;
  int keys = 0;
  @override
  Future<String> obtainKey(ImageConfiguration configuration) {
    keys++;
    return keyFuture ?? SynchronousFuture(key);
  }

  @override
  ImageStreamCompleter loadImage(String key, ImageDecoderCallback decode) {
    loads++;
    return completer;
  }
}

class _Conversion {
  _Conversion(this.convert, {this.disposeFailure, this.disposeStack});
  final Future<ByteData?> Function(ui.Image raw) convert;
  final Object? disposeFailure;
  final StackTrace? disposeStack;
  final owned = <_OwnedInfo>[];
  int conversions = 0;
  bool failDisposal = false;
}

/// The image handles are real native images. Only the conversion Future is
/// controlled so cancellation can be placed inside an otherwise native stage.
class _Image implements ui.Image {
  _Image(this.raw, this.conversion);
  final ui.Image raw;
  final _Conversion conversion;
  @override
  int get width => raw.width;
  @override
  int get height => raw.height;
  @override
  bool get debugDisposed => raw.debugDisposed;
  @override
  List<StackTrace>? debugGetOpenHandleStackTraces() =>
      raw.debugGetOpenHandleStackTraces();
  @override
  ui.Image clone() => _Image(raw.clone(), conversion);
  @override
  bool isCloneOf(ui.Image other) =>
      raw.isCloneOf(other is _Image ? other.raw : other);
  @override
  Future<ByteData?> toByteData({
    ui.ImageByteFormat format = ui.ImageByteFormat.rawRgba,
  }) {
    expect(format, ui.ImageByteFormat.png);
    conversion.conversions++;
    return conversion.convert(raw);
  }

  @override
  void dispose() => raw.dispose();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Info extends ImageInfo {
  _Info(ui.Image raw, this.conversion) : super(image: _Image(raw, conversion));
  final _Conversion conversion;
  @override
  ImageInfo clone() {
    final clone = _OwnedInfo(image.clone(), conversion);
    conversion.owned.add(clone);
    return clone;
  }
}

class _OwnedInfo extends ImageInfo {
  _OwnedInfo(ui.Image image, this.conversion) : super(image: image);
  final _Conversion conversion;
  final _disposals = [0];
  int get disposals => _disposals.single;
  @override
  void dispose() {
    _disposals[0]++;
    super.dispose();
    if (conversion.failDisposal && conversion.disposeFailure != null) {
      Error.throwWithStackTrace(
        conversion.disposeFailure!,
        conversion.disposeStack!,
      );
    }
  }
}

Future<ui.Image> _image() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xff447799), ui.BlendMode.src);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(2, 3);
  } finally {
    picture.dispose();
  }
}

Future<void> _frame() async {
  SchedulerBinding.instance.handleBeginFrame(Duration.zero);
  SchedulerBinding.instance.handleDrawFrame();
  await pumpEventQueue();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    final muted = Log.isMuted;
    Log.isMuted = true;
    addTearDown(() => Log.isMuted = muted);
  });
  tearDown(() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await _frame();
    final release = await BaseImageProvider.prepareForExit();
    release();
    expect(BaseImageProvider.debugActiveLoadCount, 0);
  });

  test(
    'synchronous real cached frame is captured without reloading or evicting success',
    () async {
      final provider = _ByteProvider(() async => _png);
      final stream = provider.resolve(ImageConfiguration.empty);
      final received = Completer<void>();
      final listener = ImageStreamListener((info, _) {
        info.dispose();
        received.complete();
      });
      stream.addListener(listener);
      await received.future;
      stream.removeListener(listener);
      await _frame();
      final scope = RequestScope();
      final reading = readImageProvider(provider, scope: scope);
      await pumpEventQueue();
      await _frame();
      final bytes = await reading;
      expect(bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
      expect(provider.loads, 1);
      expect(
        PaintingBinding.instance.imageCache.statusForKey(provider).keepAlive,
        isTrue,
      );
      scope.dispose();
    },
  );

  test('cancelled raw read waits for its actual completion', () async {
    final read = Completer<Uint8List>();
    final provider = _ByteProvider(() => read.future);
    final scope = RequestScope();
    var done = false;
    final observed = expectLater(
      readImageProvider(provider, scope: scope).whenComplete(() => done = true),
      throwsA(isA<RequestCancelled>()),
    );
    await pumpEventQueue();
    expect(provider.loads, 1);
    scope.cancel();
    await pumpEventQueue();
    await _frame();
    expect(done, isFalse);
    expect(
      PaintingBinding.instance.imageCache.statusForKey(provider).pending,
      isFalse,
    );
    read.complete(_png);
    await observed;
    expect(provider.loads, 1);
    scope.dispose();
  });

  test(
    'cancelled native frame is joined and its late image is disposed',
    () async {
      final native = Completer<ui.FrameInfo>();
      final codec = _Codec(native.future);
      final provider = _ByteProvider(
        () async => _png,
        decoder: (buffer, {getTargetSize}) async {
          buffer.dispose();
          return codec;
        },
      );
      final scope = RequestScope();
      var done = false;
      final observed = expectLater(
        readImageProvider(
          provider,
          scope: scope,
        ).whenComplete(() => done = true),
        throwsA(isA<RequestCancelled>()),
      );
      await pumpEventQueue();
      expect(codec.reads, 1);
      scope.cancel();
      await pumpEventQueue();
      await _frame();
      expect(done, isFalse);
      final image = await _image();
      native.complete(_Frame(image));
      await observed;
      expect(image.debugDisposed, isTrue);
      expect(image.debugGetOpenHandleStackTraces(), isEmpty);
      expect(codec.disposals, 1);
      scope.dispose();
    },
  );

  test(
    'synchronous stream errors preserve the original error and stack',
    () async {
      final completer = _StreamCompleter();
      final error = FormatException('cached image failed');
      final stack = StackTrace.fromString('original synchronous stream error');
      completer.addEphemeralErrorListener((_, _) {});
      completer.reportError(exception: error, stack: stack);
      final provider = _Provider(completer);
      final scope = RequestScope();
      Object? actual;
      StackTrace? actualStack;
      await readImageProvider(provider, scope: scope).then<void>(
        (_) => fail('must fail'),
        onError: (Object e, StackTrace s) {
          actual = e;
          actualStack = s;
        },
      );
      expect(actual, same(error));
      expect(actualStack, same(stack));
      expect(provider.keys, 1);
      scope.dispose();
    },
  );

  test(
    'raw failure between detach and the cache frame keeps its original stack',
    () async {
      final read = Completer<Uint8List>();
      final provider = _ByteProvider(() => read.future);
      final error = StateError('Invalid Status Code: 404 after cancel');
      final stack = StackTrace.fromString('original image read');
      final scope = RequestScope();
      final reading = readImageProvider(provider, scope: scope);
      Object? actual;
      StackTrace? actualStack;
      final observed = reading.then<void>(
        (_) => fail('must fail'),
        onError: (Object e, StackTrace s) {
          actual = e;
          actualStack = s;
        },
      );
      await pumpEventQueue();
      scope.cancel();
      await Future<void>.value();
      read.completeError(error, stack);
      await pumpEventQueue();
      await _frame();
      await observed;
      expect(actual, same(error));
      expect(actualStack, same(stack));
      scope.dispose();
    },
  );

  test(
    'an active read failure preserves one original error and stack',
    () async {
      final read = Completer<Uint8List>();
      final provider = _ByteProvider(() => read.future);
      final error = StateError('Invalid Status Code: 404');
      final stack = StackTrace.fromString('original active image read');
      final scope = RequestScope();
      Object? actual;
      StackTrace? actualStack;
      final observed = readImageProvider(provider, scope: scope).then<void>(
        (_) => fail('must fail'),
        onError: (Object e, StackTrace s) {
          actual = e;
          actualStack = s;
        },
      );
      await pumpEventQueue();
      read.completeError(error, stack);
      await pumpEventQueue();
      await _frame();
      await observed;
      expect(actual, same(error));
      expect(actualStack, same(stack));
      expect(provider.loads, 1);
      scope.dispose();
    },
  );

  test(
    'provider cancellation preserves its cause even with a live scope',
    () async {
      final completer = _StreamCompleter();
      final error = const RequestCancelled();
      final stack = StackTrace.fromString('original provider cancellation');
      final scope = RequestScope();
      Object? actual;
      StackTrace? actualStack;
      final observed = readImageProvider(_Provider(completer), scope: scope)
          .then<void>(
            (_) => fail('must fail'),
            onError: (Object e, StackTrace s) {
              actual = e;
              actualStack = s;
            },
          );
      await pumpEventQueue();
      completer.reportError(exception: error, stack: stack);
      await observed;
      expect(actual, same(error));
      expect(actualStack, same(stack));
      expect(scope.isCancelled, isFalse);
      scope.dispose();
    },
  );

  test(
    'cancel during key resolution joins the original key without starting a load',
    () async {
      final key = Completer<String>();
      final provider = _Provider(_StreamCompleter(), keyFuture: key.future);
      final scope = RequestScope();
      var done = false;
      final observed = expectLater(
        readImageProvider(
          provider,
          scope: scope,
        ).whenComplete(() => done = true),
        throwsA(isA<RequestCancelled>()),
      );
      scope.cancel();
      await pumpEventQueue();
      expect(done, isFalse);
      key.complete(provider.key);
      await observed;
      expect(provider.keys, 1);
      expect(provider.loads, 0);
      scope.dispose();
    },
  );

  test(
    'conversion cancellation waits for the real future and disposes the owned image',
    () async {
      final bytes = Completer<ByteData?>();
      final conversion = _Conversion((_) => bytes.future);
      final completer = _StreamCompleter();
      final provider = _Provider(completer);
      final scope = RequestScope();
      var done = false;
      final observed = expectLater(
        readImageProvider(
          provider,
          scope: scope,
        ).whenComplete(() => done = true),
        throwsA(isA<RequestCancelled>()),
      );
      await pumpEventQueue();
      completer.emit(_Info(await _image(), conversion));
      await pumpEventQueue();
      expect(conversion.conversions, 1);
      final owned = conversion.owned.last;
      expect(owned.disposals, 0);
      scope.cancel();
      await _frame();
      expect(done, isFalse);
      expect(owned.image.debugDisposed, isFalse);
      bytes.complete(ByteData(3));
      await observed;
      expect(owned.disposals, 1);
      expect(owned.image.debugDisposed, isTrue);
      expect(provider.keys, 1);
      expect(
        PaintingBinding.instance.imageCache
            .statusForKey(provider.key)
            .keepAlive,
        isTrue,
      );
      scope.dispose();
    },
  );

  test(
    'conversion and owned-image disposal failures retain both originals',
    () async {
      final bytes = Completer<ByteData?>();
      final conversionError = StateError('PNG conversion failed');
      final conversionStack = StackTrace.fromString('conversion stack');
      final disposeError = StateError('image disposal failed');
      final disposeStack = StackTrace.fromString('image dispose stack');
      final conversion = _Conversion(
        (_) => bytes.future,
        disposeFailure: disposeError,
        disposeStack: disposeStack,
      );
      final completer = _StreamCompleter();
      final provider = _Provider(completer);
      final scope = RequestScope();
      final observed = expectLater(
        readImageProvider(provider, scope: scope),
        throwsA(
          isA<ImageProviderPreparationFailure>().having(
            (error) => error.failures,
            'original failures',
            unorderedEquals([
              (error: conversionError, stack: conversionStack),
              (error: disposeError, stack: disposeStack),
            ]),
          ),
        ),
      );
      await pumpEventQueue();
      completer.emit(_Info(await _image(), conversion));
      await pumpEventQueue();
      expect(conversion.conversions, 1);
      conversion.failDisposal = true;
      scope.cancel();
      bytes.completeError(conversionError, conversionStack);
      await _frame();
      await observed;
      expect(conversion.owned.last.disposals, 1);
      scope.dispose();
    },
  );

  test(
    'a single conversion failure keeps its original type and stack',
    () async {
      final bytes = Completer<ByteData?>();
      final error = FormatException('native image cannot encode as PNG');
      final stack = StackTrace.fromString('original conversion stack');
      final conversion = _Conversion((_) => bytes.future);
      final completer = _StreamCompleter();
      final scope = RequestScope();
      Object? actual;
      StackTrace? actualStack;
      final observed = readImageProvider(_Provider(completer), scope: scope)
          .then<void>(
            (_) => fail('must fail'),
            onError: (Object e, StackTrace s) {
              actual = e;
              actualStack = s;
            },
          );
      await pumpEventQueue();
      completer.emit(_Info(await _image(), conversion));
      await pumpEventQueue();
      bytes.completeError(error, stack);
      await observed;
      expect(actual, same(error));
      expect(actualStack, same(stack));
      expect(conversion.owned.last.disposals, 1);
      scope.dispose();
    },
  );

  test(
    'null conversion returns an error instead of leaving the read pending',
    () async {
      final conversion = _Conversion((_) async => null);
      final completer = _StreamCompleter();
      final provider = _Provider(completer);
      final scope = RequestScope();
      final observed = expectLater(
        readImageProvider(provider, scope: scope),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'Image conversion returned no bytes',
          ),
        ),
      );
      await pumpEventQueue();
      completer.emit(_Info(await _image(), conversion));
      await _frame();
      await observed;
      expect(conversion.owned.last.image.debugDisposed, isTrue);
      scope.dispose();
    },
  );

  test(
    'only the first frame converts, including an already-dispatched late frame',
    () async {
      final raw = Uint8List.fromList([90, 91, 1, 2, 3, 92]);
      final bytes = Completer<ByteData?>();
      final conversion = _Conversion((_) => bytes.future);
      final completer = _StreamCompleter();
      final provider = _Provider(completer);
      final scope = RequestScope();
      final reading = readImageProvider(provider, scope: scope);
      await pumpEventQueue();
      final captured = completer.added.last;
      completer.emit(_Info(await _image(), conversion));
      await pumpEventQueue();
      final lateImage = await _image();
      final lateInfo = ImageInfo(image: lateImage);
      captured.onImage(lateInfo, false);
      expect(lateImage.debugDisposed, isTrue);
      completer.emit(_Info(await _image(), conversion));
      bytes.complete(ByteData.view(raw.buffer, 2, 3));
      await _frame();
      expect(await reading, [1, 2, 3]);
      expect(conversion.conversions, 1);
      expect(
        conversion.owned.every((info) => info.image.debugDisposed),
        isTrue,
      );
      scope.dispose();
    },
  );

  test(
    'cancellation hands shared raw loading to its remaining listener',
    () async {
      final read = Completer<Uint8List>();
      final provider = _ByteProvider(() => read.future);
      final scope = RequestScope();
      final observed = expectLater(
        readImageProvider(provider, scope: scope),
        throwsA(isA<RequestCancelled>()),
      );
      await pumpEventQueue();
      final shared = provider.resolve(ImageConfiguration.empty);
      final received = Completer<void>();
      final listener = ImageStreamListener((info, _) {
        info.dispose();
        received.complete();
      });
      shared.addListener(listener);
      scope.cancel();
      await observed;
      expect(read.isCompleted, isFalse);
      expect(provider.loads, 1);
      read.complete(_png);
      await received.future;
      shared.removeListener(listener);
      await _frame();
      scope.dispose();
    },
  );

  test(
    'cancelling an old stream preserves a same-key replacement pending load',
    () async {
      final oldCompleter = _StreamCompleter();
      final oldProvider = _Provider(oldCompleter);
      final replacement = _Provider(_StreamCompleter(), key: oldProvider.key);
      final scope = RequestScope();
      final observed = expectLater(
        readImageProvider(oldProvider, scope: scope),
        throwsA(isA<RequestCancelled>()),
      );
      await pumpEventQueue();
      final cache = PaintingBinding.instance.imageCache;
      cache.evict(oldProvider.key, includeLive: true);
      replacement.resolve(ImageConfiguration.empty);
      expect(cache.statusForKey(oldProvider.key).pending, isTrue);
      scope.cancel();
      await observed;
      expect(cache.statusForKey(oldProvider.key).pending, isTrue);
      expect(
        cache.putIfAbsent(
          oldProvider.key,
          () => throw StateError('replacement missing'),
        ),
        same(replacement.completer),
      );
      cache.evict(oldProvider.key, includeLive: true);
      await _frame();
      scope.dispose();
    },
  );
}
