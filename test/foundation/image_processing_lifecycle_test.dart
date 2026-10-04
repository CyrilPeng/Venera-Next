import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/image_processing.dart' as processing;

class _Codec extends Fake implements ui.Codec {
  _Codec(this.frame, this.events, {this.disposeFailure});
  final Future<ui.FrameInfo> Function() frame;
  final List<String> events;
  final Object? disposeFailure;

  @override
  Future<ui.FrameInfo> getNextFrame() => frame();

  @override
  void dispose() {
    events.add('codec');
    if (disposeFailure case final failure?) throw failure;
  }
}

class _Frame extends Fake implements ui.FrameInfo {
  _Frame(this.image);
  @override
  final ui.Image image;
}

class _DecodedImage extends Fake implements ui.Image {
  _DecodedImage(this.bytes, this.events, {this.disposeFailure});
  final Future<ByteData?> Function() bytes;
  final List<String> events;
  final Object? disposeFailure;

  @override
  int get width => 1;
  @override
  int get height => 1;
  @override
  Future<ByteData?> toByteData({
    ui.ImageByteFormat format = ui.ImageByteFormat.rawRgba,
  }) {
    expect(format, ui.ImageByteFormat.rawStraightRgba);
    return bytes();
  }

  @override
  void dispose() {
    events.add('image');
    if (disposeFailure case final failure?) throw failure;
  }
}

class _Reference extends JSInvokable {
  _Reference(this.name, this.events, {this.failure, this.result});
  final String name;
  final List<String> events;
  final Object? failure;
  final Object? result;
  var releases = 0;

  @override
  dynamic invoke(List args, [dynamic thisVal]) => result;

  @override
  void destroy() {
    releases++;
    events.add(name);
    if (failure case final error?) throw error;
  }
}

class _Port extends Fake implements ReceivePort {
  _Port(this.closePort);
  final void Function() closePort;
  @override
  void close() => closePort();
}

class _Engine extends Fake implements FlutterQjs {
  _Engine(
    this.events, {
    this.failAt,
    this.failure,
    this.closeFailure,
    this.portFailure,
    this.dispatchFailure,
  }) {
    setter = _Reference('setter', events);
    port = _Port(() {
      events.add('port');
      if (!dispatchDone.isCompleted) dispatchDone.complete();
      if (portFailure case final error?) throw error;
    });
  }
  final List<String> events;
  final int? failAt;
  final Object? failure;
  final Object? closeFailure;
  final Object? portFailure;
  final Object? dispatchFailure;
  final dispatchDone = Completer<void>();
  late _Reference setter;
  @override
  late ReceivePort port;
  Object? initResult;
  Object? scriptResult;
  Object? resultKey = 0;
  var evaluations = 0;

  @override
  Future<void> dispatch() {
    events.add('dispatch');
    if (dispatchFailure case final error?) throw error;
    return dispatchDone.future;
  }

  @override
  dynamic evaluate(String command, {String? name, int? evalFlags}) {
    if (++evaluations == failAt) throw failure!;
    return switch (evaluations) {
      1 => setter,
      2 => initResult,
      3 => scriptResult,
      _ => resultKey,
    };
  }

  @override
  void close() {
    events.add('engine');
    if (closeFailure case final error?) throw error;
  }
}

void main() {
  Future<Uint8List> execute(_Engine engine, {Object? encodeFailure}) =>
      processing.runImageScript(
        processing.Image.empty(1, 1),
        'script',
        initializationScript: 'init',
        createEngine: () => engine,
        encodeImage: (_) {
          if (encodeFailure case final error?) throw error;
          return Uint8List.fromList([1, 2, 3]);
        },
      );

  test(
    'frame failure closes the acquired codec and preserves the failure',
    () async {
      final events = <String>[];
      final failure = StateError('getNextFrame');
      final codec = _Codec(() async => throw failure, events);
      await expectLater(
        processing.Image.decodeImage(
          Uint8List(0),
          instantiateCodec: (_) async => codec,
        ),
        throwsA(same(failure)),
      );
      expect(events, ['codec']);
    },
  );

  for (final result in ['throw', 'null', 'bytes']) {
    test('pixel conversion $result always releases image and codec', () async {
      final events = <String>[];
      final failure = StateError('toByteData');
      final data = Uint32List.fromList([99, 0xff112233, 88]);
      final image = _DecodedImage(() async {
        if (result == 'throw') throw failure;
        return result == 'null' ? null : ByteData.view(data.buffer, 4, 4);
      }, events);
      final codec = _Codec(() async => _Frame(image), events);
      final decoding = processing.Image.decodeImage(
        Uint8List(0),
        instantiateCodec: (_) async => codec,
      );
      if (result == 'bytes') {
        expect((await decoding).getPixelAtIndex(0).value, 0xff112233);
      } else {
        await expectLater(
          decoding,
          throwsA(result == 'throw' ? same(failure) : isException),
        );
      }
      expect(events, ['image', 'codec']);
    });
  }

  test('decode failure keeps both image and codec cleanup failures', () async {
    final events = <String>[];
    final primary = StateError('decode');
    final imageFailure = StateError('image dispose');
    final codecFailure = StateError('codec dispose');
    final image = _DecodedImage(
      () async => throw primary,
      events,
      disposeFailure: imageFailure,
    );
    final codec = _Codec(
      () async => _Frame(image),
      events,
      disposeFailure: codecFailure,
    );
    await expectLater(
      processing.Image.decodeImage(
        Uint8List(0),
        instantiateCodec: (_) async => codec,
      ),
      throwsA(
        isA<processing.ImageProcessingFailure>()
            .having((error) => error.cause, 'decode cause', same(primary))
            .having(
              (error) => error.failures.map((entry) => entry.error),
              'all cleanup causes',
              [same(imageFailure), same(codecFailure)],
            ),
      ),
    );
    expect(events, ['image', 'codec']);
  });

  test(
    'script results release aliased and cyclic graphs before runtime and port',
    () async {
      final events = <String>[];
      final engine = _Engine(events);
      final first = _Reference('first', events);
      final second = _Reference('second', events);
      engine.setter = _Reference('setter', events, result: first);
      final graph = <Object, Object?>{
        first: [first, second],
      };
      graph['self'] = graph;
      engine.initResult = graph;
      engine.scriptResult = [first, graph];
      expect(await execute(engine), [1, 2, 3]);
      expect(events, [
        'dispatch',
        'setter',
        'first',
        'second',
        'engine',
        'port',
      ]);
      expect(first.releases, 1);
      expect(second.releases, 1);
      expect(engine.dispatchDone.isCompleted, isTrue);
    },
  );

  for (final stage in [1, 2, 3, 4]) {
    test('evaluation failure at stage $stage closes partial runtime', () async {
      final events = <String>[];
      final failure = StateError('stage $stage');
      final engine = _Engine(events, failAt: stage, failure: failure);
      await expectLater(execute(engine), throwsA(same(failure)));
      expect(events, ['dispatch', if (stage > 1) 'setter', 'engine', 'port']);
    });
  }

  test('dispatch startup failure still closes runtime and port', () async {
    final events = <String>[];
    final failure = StateError('dispatch failed');
    final engine = _Engine(events, dispatchFailure: failure);
    await expectLater(execute(engine), throwsA(same(failure)));
    expect(events, ['dispatch', 'engine', 'port']);
  });

  test(
    'asynchronous dispatch failure is observed during final cleanup',
    () async {
      final events = <String>[];
      final failure = StateError('dispatch loop');
      final engine = _Engine(events);
      engine.dispatchDone.completeError(failure);
      await expectLater(
        execute(engine),
        throwsA(
          isA<processing.ImageProcessingFailure>()
              .having(
                (error) => error.failures.single.resource,
                'resource',
                'JS dispatch',
              )
              .having(
                (error) => error.failures.single.error,
                'failure',
                same(failure),
              ),
        ),
      );
      expect(events, ['dispatch', 'setter', 'engine', 'port']);
    },
  );

  test(
    'encoding failure keeps reference, engine and port cleanup failures',
    () async {
      final events = <String>[];
      final primary = StateError('encode');
      final firstFailure = StateError('first free');
      final secondFailure = StateError('second free');
      final engineFailure = StateError('engine close');
      final portFailure = StateError('port close');
      final engine = _Engine(
        events,
        closeFailure: engineFailure,
        portFailure: portFailure,
      );
      engine.scriptResult = [
        _Reference('first', events, failure: firstFailure),
        _Reference('second', events, failure: secondFailure),
      ];
      await expectLater(
        execute(engine, encodeFailure: primary),
        throwsA(
          isA<processing.ImageProcessingFailure>()
              .having(
                (error) => error.cause,
                'original encoding failure',
                same(primary),
              )
              .having(
                (error) => error.failures.map((entry) => entry.error),
                'all cleanup failures',
                [firstFailure, secondFailure, engineFailure, portFailure],
              ),
        ),
      );
      expect(events, [
        'dispatch',
        'setter',
        'first',
        'second',
        'engine',
        'port',
      ]);
    },
  );

  test(
    'cleanup failure prevents successful bytes from hiding failed release',
    () async {
      final events = <String>[];
      final failure = StateError('close');
      final engine = _Engine(events, closeFailure: failure);
      await expectLater(
        execute(engine),
        throwsA(
          isA<processing.ImageProcessingFailure>()
              .having((error) => error.cause, 'no primary error', isNull)
              .having(
                (error) => error.failures.single.error,
                'cleanup cause',
                same(failure),
              ),
        ),
      );
      expect(events.last, 'port');
    },
  );

  test(
    'thrown JS graph references are released before returning the original error',
    () async {
      final events = <String>[];
      final reference = _Reference('thrown reference', events);
      final failure = {'reference': reference};
      final engine = _Engine(events, failAt: 3, failure: failure);
      await expectLater(execute(engine), throwsA(same(failure)));
      expect(reference.releases, 1);
      expect(events, [
        'dispatch',
        'setter',
        'thrown reference',
        'engine',
        'port',
      ]);
    },
  );
}
