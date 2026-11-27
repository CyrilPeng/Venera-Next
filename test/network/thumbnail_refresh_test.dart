import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/network/image_http_client.dart';
import 'package:venera_next/network/images.dart';
import 'package:venera_next/network/request_scope.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final ResponseBody Function(RequestOptions) respond;
  bool closed = false;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) => closed = true;
}

class _Transform extends JSInvokable {
  int calls = 0;
  int disposals = 0;
  @override
  dynamic invoke(List args, [dynamic thisVal]) {
    calls++;
    return args.single;
  }

  @override
  void destroy() {
    disposals++;
  }
}

class _GatedClient extends ImageHttpClient {
  _GatedClient(super.dio, this.entered, this.finish);
  final Completer<void> entered;
  final Completer<void> finish;
  @override
  Future<void> close({Object? cause, StackTrace? stackTrace}) async {
    entered.complete();
    await finish.future;
    await super.close(cause: cause, stackTrace: stackTrace);
  }
}

void main() {
  tearDown(() => ImageDownloader.configureSourceImageLoading());

  ImageHttpClient client(BaseOptions options, _Adapter adapter) =>
      ImageHttpClient(Dio(options)..httpClientAdapter = adapter);

  test(
    '304 retains cached bytes, source headers and the original signed URL',
    () async {
      final transforms = <_Transform>[];
      ImageDownloader.configureSourceImageLoading(
        thumbnailLoadingConfig: (_, _) {
          final transform = _Transform();
          transforms.add(transform);
          return {
            'headers': {
              'Referer': 'https://source.invalid/',
              'Cookie': 'fixture=1',
            },
            'onResponse': transform,
          };
        },
      );
      final adapter = _Adapter(
        (request) => ResponseBody.fromBytes(
          request.headers.containsKey('If-None-Match') ? [] : [1, 2, 3],
          request.headers.containsKey('If-None-Match') ? 304 : 200,
          headers: {
            'etag': ['"cover-a"'],
            'last-modified': ['Wed, 25 Nov 2026 00:00:00 GMT'],
          },
        ),
      );
      final scope = RequestScope();
      addTearDown(scope.dispose);
      const url = 'https://source.invalid/cover.png?signature=keep%2Bexact';
      final first = await ImageDownloader.refreshThumbnail(
        url,
        'source',
        'comic',
        scope,
        createClient: (options) => client(options, adapter),
      );
      final second = await ImageDownloader.refreshThumbnail(
        url,
        'source',
        'comic',
        scope,
        validators: first.validators,
        cachedBytes: first.bytes,
        createClient: (options) => client(options, adapter),
      );
      final request = adapter.requests.last;
      expect(request.uri.toString(), url);
      expect(request.headers['Referer'], 'https://source.invalid/');
      expect(request.headers['Cookie'], 'fixture=1');
      expect(request.headers['If-None-Match'], '"cover-a"');
      expect(second.bytes, [1, 2, 3]);
      expect(second.notModified, true);
      expect(transforms.map((value) => value.calls), [1, 0]);
      expect(transforms.map((value) => value.disposals), [1, 1]);
      expect(adapter.closed, true);
    },
  );

  for (final changed in ['headers', 'url', 'force']) {
    test(
      '$changed prevents reuse of validators from another request',
      () async {
        var referer = 'old';
        ImageDownloader.configureSourceImageLoading(
          thumbnailLoadingConfig: (_, _) => {
            'headers': {'Referer': referer},
          },
        );
        final adapter = _Adapter(
          (_) => ResponseBody.fromBytes(
            [1, 2],
            200,
            headers: {
              'etag': ['"a"'],
            },
          ),
        );
        final scope = RequestScope();
        addTearDown(scope.dispose);
        final first = await ImageDownloader.refreshThumbnail(
          'https://fixture.invalid/a.png',
          'source',
          'comic',
          scope,
          createClient: (options) => client(options, adapter),
        );
        if (changed == 'headers') referer = 'new';
        await ImageDownloader.refreshThumbnail(
          changed == 'url'
              ? 'https://fixture.invalid/b.png'
              : 'https://fixture.invalid/a.png',
          'source',
          'comic',
          scope,
          validators: first.validators,
          cachedBytes: first.bytes,
          force: changed == 'force',
          createClient: (options) => client(options, adapter),
        );
        expect(
          adapter.requests.last.headers.containsKey('If-None-Match'),
          false,
        );
        expect(adapter.requests.last.headers['cache-time'], 'no');
      },
    );
  }

  test(
    '304 is rejected when no cached bytes can satisfy the response',
    () async {
      final scope = RequestScope();
      addTearDown(scope.dispose);
      final adapter = _Adapter((_) => ResponseBody.fromBytes([], 304));
      await expectLater(
        ImageDownloader.refreshThumbnail(
          'https://fixture.invalid/a.png',
          'source',
          'comic',
          scope,
          createClient: (options) => client(options, adapter),
        ),
        throwsA(isA<DioException>()),
      );
      expect(adapter.closed, true);
    },
  );

  test(
    'cancellation waits for an accepted loading configuration and destroys its hook',
    () async {
      final entered = Completer<void>();
      final finish = Completer<Map<String, dynamic>>();
      ImageDownloader.configureSourceImageLoading(
        thumbnailLoadingConfig: (_, _) {
          entered.complete();
          return finish.future;
        },
      );
      final scope = RequestScope();
      addTearDown(scope.dispose);
      var settled = false;
      final pending = ImageDownloader.refreshThumbnail(
        'https://fixture.invalid/a.png',
        'source',
        'comic',
        scope,
      );
      final checked = expectLater(
        pending,
        throwsA(isA<RequestCancelled>()),
      ).then((_) => settled = true);
      await entered.future;
      scope.cancel();
      await pumpEventQueue();
      expect(settled, false);
      final transform = _Transform();
      finish.complete({'onResponse': transform});
      await checked;
      expect(transform.disposals, 1);
      expect(transform.calls, 0);
    },
  );

  test(
    'a result waits for client cleanup and cancellation during cleanup remains visible',
    () async {
      final entered = Completer<void>();
      final finish = Completer<void>();
      final adapter = _Adapter((_) => ResponseBody.fromBytes([1, 2, 3], 200));
      final scope = RequestScope();
      addTearDown(scope.dispose);
      var settled = false;
      final pending = ImageDownloader.refreshThumbnail(
        'https://fixture.invalid/a.png',
        'source',
        'comic',
        scope,
        createClient: (options) => _GatedClient(
          Dio(options)..httpClientAdapter = adapter,
          entered,
          finish,
        ),
      );
      final checked = expectLater(
        pending,
        throwsA(isA<RequestCancelled>()),
      ).then((_) => settled = true);
      await entered.future;
      scope.cancel();
      await pumpEventQueue();
      expect(settled, false);
      finish.complete();
      await checked;
      expect(adapter.closed, true);
    },
  );
}
