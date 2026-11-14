import 'package:venera_next/features/favorites/favorites_scope.dart';
import 'package:venera_next/features/history/history_scope.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/app_runtime/application_host.dart';
import 'package:venera_next/app_runtime/core_bootstrap.dart';
import 'package:venera_next/features/comic_source/source_update_service.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart'
    show
        ComicSource,
        ComicSourceManager,
        configureComicSourceRegistry,
        ChapterCommentsLoader,
        SendChapterCommentFunc,
        LikeCommentFunc,
        LoadComicPagesFunc,
        VoteCommentFunc;
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/reader/auto_reading.dart';
import 'package:venera_next/features/reader/platform_effects.dart';
import 'package:venera_next/features/reader/image_export.dart';
import 'package:venera_next/features/reader/layout_detection.dart';
import 'package:venera_next/features/reader/reader_page.dart';
import 'package:venera_next/features/reader/volume_controller.dart';
import 'package:venera_next/features/reader/window_controller.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/routing/app_navigation.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/comic_layout.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:window_manager/window_manager.dart';
import '../../../support/data_sync_fixture.dart';
import '../../../support/native_test_environment.dart';

ReaderIntegrationBinding setUpReaderIntegration() {
  final binding = ReaderIntegrationBinding();
  setUpAll(() async {
    final fontPath = Platform.environment['WINDOW_OWNER_QA_FONT'];
    if (fontPath != null) {
      final font = FontLoader('WindowOwnerQA')
        ..addFont(File(fontPath).readAsBytes().then(ByteData.sublistView));
      await font.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          File(
            windowsNativeTestFile(
              'data/flutter_assets/fonts/MaterialIcons-Regular.otf',
            ).path,
          ).readAsBytes().then(ByteData.sublistView),
        );
      await icons.load();
    }
  });
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (_) async => false,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });
  return binding;
}

const readerIntegrationChapters = ComicChapters({'one': 'One'});

History readerResumeHistory({
  int chapter = 1,
  int page = 1,
  int? group,
  int maxPage = 3,
}) => History.fromMap({
  'id': 'book',
  'type': 0,
  'time': 1000,
  'title': 'Book',
  'subtitle': '',
  'cover': '',
  'ep': chapter,
  'page': page,
  'max_page': maxPage,
  'chapter_group': group,
});

Finder readerPaintedImages(Finder consumer) => find.descendant(
  of: consumer,
  matching: find.byWidgetPredicate(
    (widget) => widget is RawImage && widget.image != null,
  ),
);

Future<void> pumpReaderUntil(
  WidgetTester tester,
  bool Function() finished,
) async {
  for (var attempt = 0; attempt < 100 && !finished(); attempt++) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(finished(), isTrue, reason: 'Reader work did not reach its gate');
}

/// Flutter's decoder remains real; only completion of its native frame future
/// is controlled. No reader, host, provider, stream or image-work wiring is
/// replaced, and tests without a gate use the normal binding unchanged.
class ReaderIntegrationBinding extends AutomatedTestWidgetsFlutterBinding {
  ReaderNativeFrameGate? nativeGate;

  @override
  Future<ui.Codec> instantiateImageCodecWithSize(
    ui.ImmutableBuffer buffer, {
    ui.TargetImageSizeCallback? getTargetSize,
  }) async {
    final gate = nativeGate;
    final codec = await super.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: getTargetSize,
    );
    return gate?.wrap(codec) ?? codec;
  }
}

class ReaderNativeFrameGate {
  final _released = Completer<void>();
  final codecs = <ReaderGatedNativeCodec>[];
  final frames = <ui.FrameInfo>[];
  int pendingFrames = 0;

  ui.Codec wrap(ui.Codec codec) {
    final owned = ReaderGatedNativeCodec(codec, this);
    codecs.add(owned);
    return owned;
  }

  void release() {
    if (!_released.isCompleted) _released.complete();
  }
}

class ReaderGatedNativeCodec implements ui.Codec {
  ReaderGatedNativeCodec(this.raw, this.gate);
  final ui.Codec raw;
  final ReaderNativeFrameGate gate;
  int disposals = 0;

  @override
  int get frameCount => raw.frameCount;
  @override
  int get repetitionCount => raw.repetitionCount;

  @override
  Future<ui.FrameInfo> getNextFrame() async {
    final frame = await raw.getNextFrame();
    gate.frames.add(frame);
    gate.pendingFrames++;
    await gate._released.future;
    gate.pendingFrames--;
    return frame;
  }

  @override
  void dispose() {
    disposals++;
    raw.dispose();
  }
}

/// Override only one fixture file. ReaderImageProvider's exists/length/read,
/// cancellation checks, native decoder and cache lifecycle still execute.
final class ReaderLocalReadGate extends IOOverrides {
  ReaderLocalReadGate(File file) : file = ReaderGatedReadFile(file);
  final ReaderGatedReadFile file;
  int get reads => file.reads;
  int get completedReads => file.completedReads;

  @override
  File createFile(String path) =>
      path.replaceAll('\\', '/') == file.path.replaceAll('\\', '/')
      ? file
      : super.createFile(path);

  void release() => file.release();
}

class ReaderGatedReadFile implements File {
  ReaderGatedReadFile(this.raw);
  final File raw;
  final _released = Completer<void>();
  int reads = 0;
  int completedReads = 0;
  @override
  String get path => raw.path;
  @override
  Future<bool> exists() => raw.exists();
  @override
  bool existsSync() => raw.existsSync();
  @override
  Future<int> length() => raw.length();
  @override
  int lengthSync() => raw.lengthSync();

  @override
  Future<Uint8List> readAsBytes() async {
    reads++;
    final bytes = await raw.readAsBytes();
    await _released.future;
    completedReads++;
    return bytes;
  }

  void release() {
    if (!_released.isCompleted) _released.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ReaderImageExporter readerFixtureExporter(
  ReaderState reader, {
  Future<Uint8List> Function(ReaderImageSelection)? read,
  required FutureOr<void> Function(ReaderImageExport) save,
  void Function(Object, StackTrace)? onError,
}) => ReaderImageExporter(
  work: reader.imageWork,
  select: () async => const ReaderImageSelection(
    imageKey: '1.png',
    sourceKey: 'local',
    comicId: 'book',
    chapterId: 'one',
    title: 'Book',
    chapter: 1,
    imageNumber: 1,
  ),
  read: read ?? (_) async => img.encodePng(img.Image(width: 1, height: 1)),
  save: save,
  share: save,
  onError: onError ?? (error, _) => fail('Unexpected export failure: $error'),
);

Future<ApplicationHost> readerFixtureHost(void Function() close) async {
  final core = CoreBootstrap(
    environment: () async {},
    settings: () async {},
    infrastructure: () async {},
    sources: () async {},
    stores: () async {},
    finish: () async {},
    failureCleanup: [(name: 'reader store', close: () async => close())],
  );
  await core.start();
  return ApplicationHost(
    core: core,
    sync: SyncTestFixture().controller,
    sourceUpdates: SourceUpdateService(),
    dataOperations: AppDataOperations(),
  );
}

class ReaderIntegrationFixture {
  ReaderIntegrationFixture()
    : previousSettings = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(appdata.toJson()['settings'])) as Map,
      ),
      previousFavorites = readerFixtureFavoritesOwner,
      previousHistory = readerFixtureHistoryOwner,
      previousLogMuted = Log.isMuted;

  final Map<String, dynamic> previousSettings;
  final LocalFavoritesManager? previousFavorites;
  final HistoryManager? previousHistory;
  final bool previousLogMuted;
  final history = ControlledReaderHistory();
  late final images = ImageFavoriteManager.create(history: history);
  final previousImages = readerFixtureImageOwner;
  final readerKey = GlobalKey<FixtureReaderState>();
  late final Directory directory;
  late WindowFrameController frame;
  int exits = 0;
  int notifications = 0;
  int imageCount = 3;

  static Future<ReaderIntegrationFixture> create(
    WidgetTester tester, {
    int imageCount = 3,
    ComicLayout? layout,
  }) async {
    final fixture = ReaderIntegrationFixture();
    fixture.imageCount = imageCount;
    fixture.directory = Directory.systemTemp.createTempSync('reader-exit-');
    App.dataPath = fixture.directory.path;
    App.cachePath = fixture.directory.path;
    Log.isMuted = true;
    readerFixtureHistoryOwner = fixture.history;
    readerFixtureImageOwner = fixture.images;
    readerFixtureFavoritesOwner = ReaderFixtureFavorites();
    final settings = appdata.settings;
    settings['comicSpecificSettings'] = <String, dynamic>{};
    settings['deviceSpecificSettings'] = <String, dynamic>{};
    settings['autoReaderMode'] = false;
    settings['readerMode'] = ReaderMode.galleryLeftToRight.key;
    settings['readerScreenPicNumberForLandscape'] = 1;
    settings['readerScreenPicNumberForPortrait'] = 1;
    settings['autoPageTurningInterval'] = 60;
    settings['autoReadingAcrossChapters'] = false;
    settings['enableClockAndBatteryInfoInReader'] = false;
    settings['showPageNumberInReader'] = false;
    settings['eInkMode'] = false;
    settings['language'] = 'en-US';
    LocalManager.current?.dispose();
    LocalManager(initializeSources: () async {});
    await tester.runAsync(() async {
      final root = fixture.directory.path;
      Directory('$root/comics').createSync();
      File('$root/local_path').writeAsStringSync('$root/comics');
      await fixture.history.init();
      await LocalManager().init();
      final png = img.encodePng(
        img.Image(
          width: 100,
          height: layout == ComicLayout.longStrip ? 400 : 150,
        ),
      );
      final cover = layout == null
          ? png
          : img.encodePng(
              img.Image(
                width: 100,
                height: layout == ComicLayout.longStrip ? 150 : 400,
              ),
            );
      final folder = Directory('${LocalManager().path}/book/one')
        ..createSync(recursive: true);
      for (var page = 1; page <= imageCount; page++) {
        File(
          '${folder.path}/$page.png',
        ).writeAsBytesSync(page == 1 ? cover : png);
      }
      await LocalManager().add(
        LocalComic(
          id: 'book',
          title: 'Book',
          subtitle: '',
          tags: const [],
          directory: 'book',
          chapters: readerIntegrationChapters,
          cover: '',
          comicType: ComicType.local,
          downloadedChapters: const ['one'],
          createdAt: DateTime(2026),
        ),
      );
    });
    return fixture;
  }

  Future<void> mount(
    WidgetTester tester, {
    required bool pushed,
    bool waitForImage = true,
    bool expectContent = true,
    bool withWindow = true,
    SelectionTaskRegistry? registry,
    ValueNotifier<SelectionTaskRegistry>? registries,
    WindowFinalizer? finalize,
    ReaderVolumeConnection Function(void Function(Object?))? volumeConnect,
    ReaderWindowCoordinator? windowCoordinator,
    double textScale = 1,
    bool reducedMotion = false,
    Brightness brightness = Brightness.light,
    void Function(WindowFrameController)? beforeReaderMount,
    ComicChapters? chapters = readerIntegrationChapters,
    String comicId = 'book',
    ComicType comicType = ComicType.local,
    History? savedHistory,
    int? initialChapter,
    int? initialPage,
    int? initialChapterGroup,
  }) async {
    var registered = false;
    Widget reader() => Scaffold(
      body: FixtureReader(
        key: readerKey,
        onClosed: () => notifications++,
        volumeConnect: volumeConnect,
        windowCoordinator: windowCoordinator,
        chapters: chapters,
        comicId: comicId,
        comicType: comicType,
        savedHistory: savedHistory,
        initialChapter: initialChapter,
        initialPage: initialPage,
        initialChapterGroup: initialChapterGroup,
      ),
    );
    if (volumeConnect != null) {
      appdata.settings['enableTurnPageByVolumeKey'] = true;
      appdata.settings['enablePageAnimation'] = false;
    }
    await tester.pumpWidget(
      readerFixtureLibraryView(
        MaterialApp(
          theme: ThemeData(
            brightness: brightness,
            fontFamily: Platform.environment['WINDOW_OWNER_QA_FONT'] == null
                ? null
                : 'WindowOwnerQA',
          ),
          navigatorKey: appNavigation.rootNavigatorKey,
          builder: (context, child) {
            Widget content = ReaderPlatformEffectsScope(
              child: OverlayWidget(child!),
            );
            if (withWindow) {
              content = WindowFrame(
                Builder(
                  builder: (context) {
                    frame = WindowFrame.of(context);
                    if (!registered) {
                      registered = true;
                      beforeReaderMount?.call(frame);
                    }
                    return ReaderPlatformEffectsScope(
                      child: OverlayWidget(child),
                    );
                  },
                ),
                onExit: () => exits++,
                finalize: finalize,
              );
            }
            content = MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(textScale),
                disableAnimations: reducedMotion,
              ),
              child: content,
            );
            if (registries != null) {
              return ValueListenableBuilder<SelectionTaskRegistry>(
                valueListenable: registries,
                child: content,
                builder: (_, registry, child) =>
                    SelectionTasksScope(registry: registry, child: child!),
              );
            }
            return registry == null
                ? content
                : SelectionTasksScope(registry: registry, child: content);
          },
          home: pushed ? const Scaffold(body: Text('Library home')) : reader(),
        ),
      ),
    );
    if (pushed) {
      unawaited(
        appNavigation.rootNavigatorKey.currentState!.push<void>(
          MaterialPageRoute(builder: (_) => reader()),
        ),
      );
    }
    if (!expectContent) {
      await tester.pump(const Duration(seconds: 1));
      return;
    }
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      final current = readerKey.currentState;
      if (!waitForImage &&
          current?.imageViewController is AutoReadingViewport &&
          current?.isLoading == false) {
        break;
      }
      if (current?.imageViewController case AutoReadingViewport viewport
          when viewport.autoReadingReady && !current!.isLoading) {
        break;
      }
    }
    expect(readerKey.currentState?.images, hasLength(imageCount));
    expect(readerKey.currentState?.isLoading, isFalse);
    expect(
      readerKey.currentState?.imageViewController,
      isA<AutoReadingViewport>(),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
  }

  void closeWindow(WidgetTester tester) =>
      (tester.state(find.byType(WindowFrame)) as WindowListener)
          .onWindowClose();

  Future<void> dispose(WidgetTester tester) async {
    history.onProgress = null;
    history.onDuration = null;
    readerKey.currentState?.autoReading.stop();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    LocalManager.current?.dispose();
    history.close();
    images.dispose();
    readerFixtureImageOwner = previousImages;
    readerFixtureHistoryOwner = previousHistory;
    readerFixtureFavoritesOwner = previousFavorites;
    Log.isMuted = previousLogMuted;
    previousSettings.forEach((key, value) => appdata.settings[key] = value);
    directory.deleteSync(recursive: true);
  }
}

Comment readerFixtureComment(String text) =>
    Comment.fromJson({'id': text, 'userName': 'Reader', 'content': text});

class ReaderFixtureCommentSource extends Fake implements ComicSource {
  Future<Res<List<Comment>>> Function() load = () async => Res([], subData: 1);
  Future<Res<bool>> Function() send = () async => const Res(true);
  @override
  String get key => 'local';
  @override
  ChapterCommentsLoader get chapterCommentsLoader =>
      (_, _, _, _) => load();
  @override
  SendChapterCommentFunc get sendChapterCommentFunc =>
      (_, _, _, _) => send();
  @override
  LikeCommentFunc? get likeCommentFunc => null;
  @override
  VoteCommentFunc? get voteCommentFunc => null;
}

class ReaderFixturePagesSource extends ReaderFixtureCommentSource {
  ReaderFixturePagesSource(this._loadPages);
  final LoadComicPagesFunc _loadPages;
  @override
  String get key => 'replacement';
  @override
  LoadComicPagesFunc get loadComicPages => _loadPages;
}

void Function() readerFixtureCommentRegistry(
  ReaderFixtureCommentSource Function() source,
) {
  final manager = ComicSourceManager();
  configureComicSourceRegistry(
    all: manager.all,
    find: (key) => key == 'local' ? source() : manager.find(key),
    fromIntKey: manager.fromIntKey,
    isEmpty: () => false,
  );
  return () => configureComicSourceRegistry(
    all: manager.all,
    find: manager.find,
    fromIntKey: manager.fromIntKey,
    isEmpty: () => manager.isEmpty,
  );
}

class ReaderFixtureOtherComicType extends ComicType {
  const ReaderFixtureOtherComicType() : super(42);
  @override
  String get sourceKey => 'replacement';
}

class FixtureReader extends Reader {
  FixtureReader({
    required super.key,
    required super.onClosed,
    this.volumeConnect,
    this.windowCoordinator,
    super.chapters = readerIntegrationChapters,
    String comicId = 'book',
    ComicType comicType = ComicType.local,
    History? savedHistory,
    super.initialChapter,
    super.initialPage,
    super.initialChapterGroup,
  }) : super(
         type: comicType,
         cid: comicId,
         name: 'Book',
         author: '',
         tags: const [],
         history: savedHistory ?? readerResumeHistory(),
       );

  final ReaderVolumeConnection Function(void Function(Object?))? volumeConnect;
  final ReaderWindowCoordinator? windowCoordinator;

  @override
  ReaderState createState() => FixtureReaderState();
}

class FixtureReaderState extends ReaderState {
  ComicLayoutProbe? layoutProbe;
  Future<void> Function()? onSaveSettings;
  int settingsSaves = 0;

  @override
  ReaderWindowCoordinator get windowCoordinator =>
      (widget as FixtureReader).windowCoordinator ?? super.windowCoordinator;

  @override
  bool get supportsVolumeKeys =>
      (widget as FixtureReader).volumeConnect != null;

  @override
  ReaderVolumeConnection createVolumeConnection(void Function(Object?) send) =>
      (widget as FixtureReader).volumeConnect!(send);

  @override
  ComicLayoutProbe createLayoutProbe() =>
      layoutProbe ?? super.createLayoutProbe();

  @override
  Future<void> saveReadingSettings(void Function(Settings draft) edit) {
    settingsSaves++;
    if (onSaveSettings case final save?) {
      edit(appdata.settings);
      return save();
    }
    return super.saveReadingSettings(edit);
  }

  @override
  void setImageCacheSize() {}
}

class ReaderFixtureVolumeLease implements ReaderVolumeConnection {
  ReaderFixtureVolumeLease(this.send, {this.release});
  final void Function(Object?) send;
  final Future<void> Function()? release;
  int closes = 0;
  @override
  Future<void> get ready => Future.value();
  @override
  Future<void> closeAndWait() async {
    closes++;
    await release?.call();
  }
}

/// Separate UI and cleanup gates; the real reader/session/window owns both.
class ReaderLayoutProbeGate extends ComicLayoutProbe {
  final _result = Completer<ComicLayoutDetection>();
  final _cleanup = Completer<void>();
  bool started = false;
  bool _cancelled = false;

  @override
  bool get isCancelled => _cancelled;
  @override
  Future<void> get done => _cleanup.future;

  @override
  Future<ComicLayoutDetection> detect({
    required List<String> images,
    required String? sourceKey,
    required String comicId,
    required String chapterId,
  }) {
    started = true;
    return _result.future;
  }

  @override
  void cancel() {
    _cancelled = true;
    if (!_result.isCompleted) {
      _result.complete(const ComicLayoutDetection(ComicLayout.unknown, 0));
    }
  }

  void finish([ComicLayout layout = ComicLayout.unknown]) {
    if (!_cleanup.isCompleted) _cleanup.complete();
    if (!_result.isCompleted) _result.complete(ComicLayoutDetection(layout, 6));
  }
}

class ControlledReaderHistory extends HistoryManager {
  ControlledReaderHistory() : super.create();

  final progress = <History>[];
  final durations = <Duration>[];
  Future<void> Function(History)? onProgress;
  Future<void> Function(Duration)? onDuration;

  @override
  Future<void> addHistory(History history) {
    final snapshot = history.copy();
    progress.add(snapshot);
    return onProgress?.call(snapshot) ?? Future.value();
  }

  @override
  Future<void> addReadDuration(History history, Duration duration) async {
    durations.add(duration);
    await onDuration?.call(duration);
  }
}

class ReaderFixtureFavorites extends ChangeNotifier
    implements LocalFavoritesManager {
  @override
  int get connectionGeneration => 1;
  Future<void>? reading;
  int reads = 0;

  @override
  Future<void> onRead(
    String id,
    ComicType type, {
    int? generation,
    void Function()? checkActive,
  }) async {
    checkActive?.call();
    reads++;
    await reading;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ReaderPlatformEffectsProbe {
  final events = <String>[];
  String orientation = '';
  bool barsVisible = true;
  Future<void> Function(String)? onOrientation;
  Future<void> Function(bool)? onBars;

  void install() => TestDefaultBinaryMessengerBinding
      .instance
      .defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'SystemChrome.setPreferredOrientations') {
          final value = (call.arguments as List).join(',');
          events.add('orientation:$value');
          await onOrientation?.call(value);
          orientation = value;
        } else if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
          final value = call.arguments == 'SystemUiMode.edgeToEdge';
          events.add('bars:$value');
          await onBars?.call(value);
          barsVisible = value;
        }
        return null;
      });

  void uninstall() => TestDefaultBinaryMessengerBinding
      .instance
      .defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
}

class ReaderFixtureNativeWindow {
  bool fullscreen = false;
  bool visible = true;
  final events = <String>[];
  Future<void> Function(bool)? onFullscreen;
  Future<void> Function()? onShow;
  late final coordinator = ReaderWindowCoordinator(
    hide: () async {
      events.add('hide');
      visible = false;
    },
    show: () async {
      events.add('show');
      await onShow?.call();
      visible = true;
    },
    setFullscreen: (value) async {
      events.add('fullscreen:$value');
      await onFullscreen?.call(value);
      fullscreen = value;
    },
  );
}

LocalFavoritesManager? readerFixtureFavoritesOwner;
LocalFavoritesManager readerFixtureFavoritesForView() =>
    readerFixtureFavoritesOwner ??= LocalFavoritesManager.independent();
HistoryManager? readerFixtureHistoryOwner;
HistoryManager readerFixtureHistoryForView() =>
    readerFixtureHistoryOwner ??= HistoryManager.create();
Widget? readerFixtureLibraryChild;
ImageFavoriteManager? readerFixtureImageOwner;
Widget readerFixtureLibraryView(Widget child) {
  readerFixtureLibraryChild = child;
  return FavoritesScope(
    manager: readerFixtureFavoritesForView(),
    child: HistoryScope(
      manager: readerFixtureHistoryForView(),
      imageFavorites: readerFixtureImageOwner,
      child: child,
    ),
  );
}

Future<void> replaceReaderFixtureHistory(
  WidgetTester tester,
  HistoryManager manager, {
  ImageFavoriteManager? images,
}) async {
  readerFixtureHistoryOwner = manager;
  final next = images ?? ImageFavoriteManager.create(history: manager);
  if (images == null) addTearDown(next.dispose);
  readerFixtureImageOwner = next;
  await tester.pumpWidget(readerFixtureLibraryView(readerFixtureLibraryChild!));
}
