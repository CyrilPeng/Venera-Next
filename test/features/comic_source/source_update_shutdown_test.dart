import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera_next/features/comic_source/comic_source_manager.dart';
import 'package:venera_next/features/comic_source/source.dart';
import 'package:venera_next/features/comic_source/source_failure.dart';
import 'package:venera_next/features/comic_source/source_update_service.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/app_dio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late Map<String, dynamic> settings;
  late bool muted;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('source-shutdown-');
    App.dataPath = directory.path;
    settings = jsonDecode(jsonEncode(appdata.toJson()['settings']));
    appdata.settings['comicSourceRepositories'] = [];
    appdata.settings['comicSourceOrigins'] = {};
    muted = Log.isMuted;
    Log.isMuted = true;
  });
  tearDown(() async {
    final manager = ComicSourceManager();
    for (final source in manager.all()) {
      manager.remove(source.key);
    }
    await manager.closeAndWait();
    settings.forEach((key, value) => appdata.settings[key] = value);
    Log.isMuted = muted;
    directory.deleteSync(recursive: true);
  });

  test(
    'final close joins retired and current requests through native idle',
    () async {
      final adapters = <_Adapter>[];
      final service = SourceUpdateService(
        createDio: () {
          final adapter = _Adapter();
          adapters.add(adapter);
          return Dio()..httpClientAdapter = adapter;
        },
      );
      final source = _registeredSource();
      final old = expectLater(service.update(source), throwsA(_cancelled));
      await pumpEventQueue();
      service.cancel(source.key);
      final current = expectLater(service.update(source), throwsA(_cancelled));
      await pumpEventQueue();
      expect(adapters, hasLength(2));
      var closed = false;
      final closing = service.closeAndWait();
      expect(identical(closing, service.closeAndWait()), isTrue);
      final done = closing.then((_) => closed = true);
      await Future.wait(adapters.map((adapter) => adapter.draining.future));
      adapters.last.released.complete();
      await pumpEventQueue();
      expect(closed, isFalse);
      adapters.first.released.complete();
      await Future.wait([old, current, done]);
      expect(closed, isTrue);
      expect(adapters.every((adapter) => adapter.forced), isTrue);
      expect(service.isUpdating(source.key), isFalse);
      await expectLater(service.update(source), throwsStateError);
      await expectLater(service.checkUpdates(), throwsStateError);
    },
  );

  test(
    'checking uses one owned client and cancellation stops the next repository',
    () async {
      final manager = ComicSourceManager();
      for (final key in ['a', 'b']) {
        manager.add(_source(key: key));
      }
      appdata.settings['comicSourceRepositories'] = [
        for (final key in ['a', 'b'])
          {'id': key, 'name': key, 'url': 'https://example.test/$key.json'},
      ];
      appdata.settings['comicSourceOrigins'] = {
        for (final key in ['a', 'b'])
          key: {'kind': 'repository', 'repositoryId': key},
      };
      final adapter = _Adapter();
      final service = SourceUpdateService(
        createDio: () => Dio()..httpClientAdapter = adapter,
      );
      var published = false;
      final checking = service.checkUpdates();
      checking.then<void>((_) {
        published = true;
      }, onError: (Object _, StackTrace _) {});
      expect(identical(checking, service.checkUpdates()), isTrue);
      final checked = expectLater(checking, throwsA(_cancelled));
      await adapter.entered.future;
      final closing = service.closeAndWait();
      await adapter.draining.future;
      expect(adapter.urls, ['https://example.test/a.json']);
      expect(published, isFalse);
      adapter.released.complete();
      await Future.wait([checked, closing]);
      expect(published, isFalse);
    },
  );

  test(
    'operation, force-close and native-drain errors remain inspectable',
    () async {
      final operationError = StateError('request');
      final closeError = StateError('force close');
      final drainError = StateError('native drain');
      final adapter = _Adapter()..closeError = closeError;
      final service = SourceUpdateService(
        createDio: () => Dio()..httpClientAdapter = adapter,
      );
      final updating = service.update(_registeredSource());
      final checked = expectLater(
        updating,
        throwsA(
          isA<SourceUpdateCloseFailure>()
              .having(
                (error) => (error.cause as DioException).error,
                'operation',
                same(operationError),
              )
              .having((error) => error.causeStack, 'operation stack', isNotNull)
              .having(
                (error) => error.failures.map((failure) => failure.error),
                'cleanup errors',
                [closeError, drainError],
              ),
        ),
      );
      await adapter.entered.future;
      adapter.response.completeError(operationError);
      await adapter.draining.future;
      adapter.released.completeError(drainError);
      await checked;
      final closing = service.closeAndWait();
      await expectLater(closing, throwsA(isA<SourceUpdateCloseFailure>()));
      expect(identical(closing, service.closeAndWait()), isTrue);
      expect(adapter.closes, 1);
    },
  );

  test(
    'real native cancellation waits for the upload subscription to release',
    () async {
      await rhttp.Rhttp.init();
      final previousVersion = App.version;
      final previousInitialized = App.isInitialized;
      App.version = 'source-shutdown-test';
      App.isInitialized = false;
      appdata.settings['proxy'] = 'direct';
      final released = Completer<void>();
      final cancelling = Completer<void>();
      final upload = StreamController<Uint8List>(
        onCancel: () {
          cancelling.complete();
          return released.future;
        },
      );
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      final received = Completer<void>();
      server.listen((socket) {
        sockets.add(socket);
        socket.listen((_) {
          if (!received.isCompleted) received.complete();
        }, onError: (Object _) {});
      });
      final service = SourceUpdateService(
        createDio: () {
          final dio = Dio()..httpClientAdapter = RHttpAdapter();
          dio.interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                options.data = upload.stream;
                handler.next(options);
              },
            ),
          );
          return dio;
        },
      );
      addTearDown(() async {
        if (!released.isCompleted) released.complete();
        await service.closeAndWait();
        unawaited(upload.close());
        for (final socket in sockets) {
          socket.destroy();
        }
        await server.close();
        App.version = previousVersion;
        App.isInitialized = previousInitialized;
      });
      final updated = expectLater(
        service.update(
          _registeredSource(url: 'http://127.0.0.1:${server.port}/source.js'),
        ),
        throwsA(_cancelled),
      );
      await received.future.timeout(const Duration(seconds: 10));
      var closed = false;
      final closing = service.closeAndWait().then((_) => closed = true);
      await cancelling.future.timeout(const Duration(seconds: 10));
      await pumpEventQueue();
      expect(closed, isFalse);
      released.complete();
      await Future.wait([
        updated,
        closing,
      ]).timeout(const Duration(seconds: 10));
    },
    skip: !Platform.isWindows,
  );
}

final _cancelled = isA<SourceFailure>().having(
  (error) => error.code,
  'code',
  SourceFailureCode.cancelled,
);

ComicSource _registeredSource({
  String key = 'source',
  String url = 'https://example.test/source.js',
}) {
  final source = _source(key: key, url: url);
  ComicSourceManager().add(source);
  return source;
}

ComicSource _source({
  String key = 'source',
  String url = 'https://example.test/source.js',
}) => ComicSource(
  key,
  key,
  null,
  null,
  null,
  null,
  const [],
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  '$key.js',
  url,
  '1.0.0',
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  false,
  false,
  null,
  null,
);

class _Adapter extends RHttpAdapter {
  final response = Completer<ResponseBody>();
  final entered = Completer<void>();
  final draining = Completer<void>();
  final released = Completer<void>();
  final urls = <String>[];
  Object? closeError;
  bool forced = false;
  int closes = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    urls.add(options.uri.toString());
    if (!entered.isCompleted) entered.complete();
    return Future.any([
      response.future,
      if (cancelFuture != null)
        cancelFuture.then<ResponseBody>(
          (_) => throw options.cancelToken!.cancelError!,
        ),
    ]);
  }

  @override
  void close({bool force = false}) {
    closes++;
    forced = force;
    if (closeError != null) throw closeError!;
  }

  @override
  Future<void> waitForIdle() {
    if (!draining.isCompleted) draining.complete();
    return released.future;
  }
}
