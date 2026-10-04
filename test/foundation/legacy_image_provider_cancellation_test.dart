import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/history/history_api.dart';
import 'package:venera_next/features/history/history_image_provider.dart';
import 'package:venera_next/features/history/image_favorites_provider.dart';
import 'package:venera_next/features/local_comics/local_comic_image.dart';
import 'package:venera_next/features/local_comics/local_comic_model.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/image_provider/base_image_provider.dart';
import 'package:venera_next/foundation/image_provider/image_provider_lifecycle.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/images.dart';
import 'package:venera_next/network/image_stream.dart';
import 'package:venera_next/network/shared_request_stream.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late bool previousLogMuted;
  setUp(() {
    previousLogMuted = Log.isMuted;
    Log.isMuted = true;
  });
  tearDown(() async {
    await pumpEventQueue();
    Log.isMuted = previousLogMuted;
    expect(BaseImageProvider.debugActiveLoadCount, 0);
  });

  for (final kind in ['history', 'image favorites']) {
    test(
      '$kind cancels a silent stream and waits for subscription cleanup',
      () async {
        final cleanup = Completer<void>();
        var cancellations = 0;
        final source = StreamController<ImageDownloadProgress>(
          onCancel: () {
            cancellations++;
            return cleanup.future;
          },
        );
        final load = _ActiveLoad(_streamProvider(kind, source.stream));
        await pumpEventQueue();
        expect(source.hasListener, isTrue);
        var drained = false;
        final preparation = BaseImageProvider.prepareForExit().then((release) {
          drained = true;
          return release;
        });
        try {
          await pumpEventQueue();
          expect(cancellations, 1);
          expect(drained, isFalse);
          expect(BaseImageProvider.debugActiveLoadCount, 1);
          cleanup.complete();
          final release = await preparation;
          load.dispose();
          release();
          expect(load.errors, isEmpty);
        } finally {
          if (!cleanup.isCompleted) cleanup.complete();
          load.dispose();
          (await preparation)();
          await source.close();
        }
      },
    );

    test(
      '$kind releases its own listener without cancelling a shared peer',
      () async {
        var cancellations = 0;
        final source = StreamController<ImageDownloadProgress>(
          onCancel: () => cancellations++,
        );
        final shared = SharedRequestStream<ImageDownloadProgress>(
          (_) => source.stream,
          (_) {},
        );
        final peerEvents = <ImageDownloadProgress>[];
        final peer = shared.stream.listen(peerEvents.add);
        final load = _ActiveLoad(_streamProvider(kind, shared.stream));
        await pumpEventQueue();
        final release = await BaseImageProvider.prepareForExit();
        load.dispose();
        release();
        expect(cancellations, 0);
        const event = ImageDownloadProgress(currentBytes: 1, totalBytes: 2);
        source.add(event);
        await pumpEventQueue();
        expect(peerEvents, [event]);
        expect(load.errors, isEmpty);
        await peer.cancel();
        expect(cancellations, 1);
        await source.close();
      },
    );
  }

  for (final stage in ['local', 'cache', 'network', 'write']) {
    for (final fail in [false, true]) {
      test(
        'image favorite $stage waits for accepted work after cancel; failure=$fail',
        () async {
          final gate = Completer<Uint8List?>();
          final writeGate = Completer<void>();
          final provider = _FavoriteProvider();
          switch (stage) {
            case 'local':
              provider.local = () => gate.future;
            case 'cache':
              provider.cache = () => gate.future;
            case 'network':
              provider.network = () async => (await gate.future)!;
            case 'write':
              provider.write = () => writeGate.future;
          }
          final events = StreamController<ImageChunkEvent>.broadcast();
          var stopped = false;
          var settled = false;
          final error = FileSystemException('late $stage failure');
          final stack = StackTrace.current;
          final loading = provider.load(events, () {
            if (stopped) throw const ImageProviderLoadCancelled();
          });
          final observed = _failure(loading).then((failure) {
            settled = true;
            return failure;
          });
          await pumpEventQueue();
          stopped = true;
          await pumpEventQueue();
          expect(settled, isFalse);
          if (stage == 'write') {
            if (fail) {
              writeGate.completeError(error, stack);
            } else {
              writeGate.complete();
            }
          } else if (fail) {
            gate.completeError(error, stack);
          } else {
            gate.complete(stage == 'network' ? Uint8List.fromList([1]) : null);
          }
          final failure = await observed;
          expect(
            failure.error,
            fail ? same(error) : isA<ImageProviderLoadCancelled>(),
          );
          if (fail) expect(failure.stack, same(stack));
          expect(provider.keyLookups, 0);
          expect(provider.writes, stage == 'write' ? 1 : 0);
          if (stage == 'local') expect(provider.cacheReads, 0);
          if (stage == 'local' || stage == 'cache') {
            expect(provider.networkReads, 0);
          }
          await events.close();
        },
      );
    }
  }

  test(
    'image favorite cleanup failure cannot trigger a URL refresh or cache write',
    () async {
      final error = ImageStreamCleanupFailure([
        (
          stage: 'cancel',
          error: StateError('cancel failed'),
          stack: StackTrace.current,
        ),
      ]);
      final provider = _FavoriteProvider()..network = () => Future.error(error);
      final events = StreamController<ImageChunkEvent>.broadcast();
      await expectLater(provider.load(events, () {}), throwsA(same(error)));
      expect(provider.keyLookups, 0);
      expect(provider.networkReads, 1);
      expect(provider.writes, 0);
      await events.close();
    },
  );

  test(
    'image favorite cancellation during URL refresh cannot start another download',
    () async {
      final key = Completer<String>();
      final provider = _FavoriteProvider();
      provider.network = () => Future.error(StateError('stale image URL'));
      provider.lookup = () => key.future;
      var stopped = false;
      final events = StreamController<ImageChunkEvent>.broadcast();
      final loading = provider.load(events, () {
        if (stopped) throw const ImageProviderLoadCancelled();
      });
      final observed = expectLater(
        loading,
        throwsA(isA<ImageProviderLoadCancelled>()),
      );
      await pumpEventQueue();
      expect(provider.keyLookups, 1);
      stopped = true;
      key.complete('replacement');
      await observed;
      expect(provider.networkReads, 1);
      expect(provider.writes, 0);
      await events.close();
    },
  );

  test(
    'local comic cancellation during existence lookup cannot start a read or scan',
    () async {
      final exists = Completer<bool>();
      final file = _File('root/cover.png')..existence = () => exists.future;
      final directory = _Directory('root');
      final provider = _ComicProvider(file, directory);
      final events = StreamController<ImageChunkEvent>.broadcast();
      var stopped = false;
      final loading = provider.load(events, () {
        if (stopped) throw const ImageProviderLoadCancelled();
      });
      final observed = expectLater(
        loading,
        throwsA(isA<ImageProviderLoadCancelled>()),
      );
      await pumpEventQueue();
      stopped = true;
      exists.complete(false);
      await observed;
      expect(file.reads, 0);
      expect(directory.existsCalls, 0);
      expect(directory.listCalls, 0);
      await events.close();
    },
  );

  test(
    'local comic preserves the original failed read after cancellation',
    () async {
      final reading = Completer<Uint8List>();
      final file = _File('root/cover.png')..read = () => reading.future;
      final provider = _ComicProvider(file, _Directory('root'));
      final events = StreamController<ImageChunkEvent>.broadcast();
      var stopped = false;
      final observed = _failure(
        provider.load(events, () {
          if (stopped) throw const ImageProviderLoadCancelled();
        }),
      );
      await pumpEventQueue();
      expect(file.reads, 1);
      stopped = true;
      final error = FileSystemException('read failed');
      final stack = StackTrace.current;
      reading.completeError(error, stack);
      final failure = await observed;
      expect(failure.error, same(error));
      expect(failure.stack, same(stack));
      await events.close();
    },
  );
  test(
    'local comic waits for directory listing and stops before the next chapter scan',
    () async {
      final entries = StreamController<FileSystemEntity>();
      final chapter = _Directory('root/chapter');
      final root = _Directory('root')..entries = () => entries.stream;
      final file = _File('root/cover.png')..existence = () async => false;
      final provider = _ComicProvider(file, root);
      final events = StreamController<ImageChunkEvent>.broadcast();
      var stopped = false;
      var settled = false;
      final observed =
          _failure(
            provider.load(events, () {
              if (stopped) throw const ImageProviderLoadCancelled();
            }),
          ).then((failure) {
            settled = true;
            return failure;
          });
      await pumpEventQueue();
      expect(root.listCalls, 1);
      stopped = true;
      await pumpEventQueue();
      expect(settled, isFalse);
      entries.add(chapter);
      await entries.close();
      expect((await observed).error, isA<ImageProviderLoadCancelled>());
      expect(chapter.listCalls, 0);
      expect(file.reads, 0);
      await events.close();
    },
  );
}

Future<({Object error, StackTrace stack})> _failure(
  Future<dynamic> future,
) async {
  try {
    await future;
  } catch (error, stack) {
    return (error: error, stack: stack);
  }
  throw TestFailure('Expected the accepted load to fail');
}

BaseImageProvider _streamProvider(
  String kind,
  Stream<ImageDownloadProgress> source,
) => switch (kind) {
  'history' => _HistoryProvider(source),
  'image favorites' => _FavoriteProvider()..source = source,
  _ => throw ArgumentError.value(kind, 'kind'),
};

class _ActiveLoad {
  _ActiveLoad(BaseImageProvider provider) {
    Future<ui.Codec> decode(
      ui.ImmutableBuffer buffer, {
      ui.TargetImageSizeCallback? getTargetSize,
    }) async {
      buffer.dispose();
      throw StateError('Cancelled provider must not decode');
    }

    completer =
        (provider as dynamic).loadImage(provider, decode)
            as ImageStreamCompleter;
    listener = ImageStreamListener((image, _) {
      image.dispose();
      errors.add(StateError('Unexpected image publication'));
    }, onError: (Object error, StackTrace? _) => errors.add(error));
    completer.addListener(listener);
  }
  late final ImageStreamCompleter completer;
  late final ImageStreamListener listener;
  final errors = <Object>[];
  bool disposed = false;
  void dispose() {
    if (disposed) return;
    disposed = true;
    completer.removeListener(listener);
  }
}

class _HistoryProvider extends HistoryImageProvider {
  _HistoryProvider(this.source)
    : super(
        History(
          type: ComicType.local,
          time: DateTime(2026),
          title: 'Book',
          subtitle: '',
          cover: 'https://example.invalid/cover',
          ep: 1,
          page: 1,
          id: 'book',
          readEpisode: {},
          maxPage: 1,
          readDurationMs: 0,
        ),
      );
  final Stream<ImageDownloadProgress> source;
  @override
  Stream<ImageDownloadProgress> loadThumbnail(
    String url,
    String? sourceKey,
    String id,
  ) => source;
}

class _FavoriteProvider extends ImageFavoritesProvider {
  _FavoriteProvider()
    : super(
        ImageFavorite(
          1,
          'known-image',
          false,
          'one',
          'book',
          1,
          'source',
          'One',
        ),
      );
  Future<Uint8List?> Function()? local;
  Future<Uint8List?> Function()? cache;
  Future<Uint8List> Function()? network;
  Future<String> Function()? lookup;
  Future<void> Function()? write;
  Stream<ImageDownloadProgress>? source;
  int cacheReads = 0, networkReads = 0, keyLookups = 0, writes = 0;
  @override
  Future<Uint8List?> getImageFromLocal({void Function()? checkStop}) =>
      local?.call() ?? Future.value();
  @override
  Future<Uint8List?> readFromCache() {
    cacheReads++;
    return cache?.call() ?? Future.value();
  }

  @override
  Future<Uint8List> getImageFromNetwork(
    String key,
    StreamController<ImageChunkEvent>? events,
    void Function()? checkStop,
  ) {
    networkReads++;
    if (source != null) {
      return super.getImageFromNetwork(key, events, checkStop);
    }
    return network?.call() ?? Future.value(Uint8List.fromList([1]));
  }

  @override
  Stream<ImageDownloadProgress> loadComicImage(String imageKey) => source!;
  @override
  Future<String> getImageKey() {
    keyLookups++;
    return lookup?.call() ?? Future.value('refreshed-image');
  }

  @override
  Future<void> writeToCache(Uint8List image) {
    writes++;
    return write?.call() ?? Future.value();
  }
}

class _ComicProvider extends LocalComicImageProvider {
  _ComicProvider(this.file, this.directory) : super(_Comic());
  final File file;
  final Directory directory;
  @override
  File get coverFile => file;
  @override
  Directory get comicDirectory => directory;
}

class _Comic extends Fake implements LocalComic {}

class _File extends Fake implements File {
  _File(this.path);
  @override
  final String path;
  Future<bool> Function()? existence;
  Future<Uint8List> Function()? read;
  int reads = 0;
  @override
  Future<bool> exists() => existence?.call() ?? Future.value(true);
  @override
  Future<Uint8List> readAsBytes() {
    reads++;
    return read?.call() ?? Future.value(Uint8List.fromList([1]));
  }
}

class _Directory extends Fake implements Directory {
  _Directory(this.path);
  @override
  final String path;
  Stream<FileSystemEntity> Function()? entries;
  int existsCalls = 0, listCalls = 0;
  @override
  Future<bool> exists() async {
    existsCalls++;
    return true;
  }

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) {
    listCalls++;
    return entries?.call() ?? const Stream.empty();
  }
}
