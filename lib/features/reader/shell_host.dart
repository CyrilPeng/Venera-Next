import 'package:flutter/material.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_profile.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/reader_preferences.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'subtitles/controls.dart';
import 'subtitles/overlay.dart';
import 'subtitles/store.dart';
import 'reader_page.dart';
import 'scaffold.dart';
import 'shell_data.dart';

/// Widget composition is the only shell layer that knows the reader State.
/// Page reports rebuild the shell while retaining the content subtree.
class ReaderShellHost extends StatefulWidget {
  const ReaderShellHost({super.key, required this.reader, required this.child});
  final ReaderState reader;
  final Widget child;

  @override
  State<ReaderShellHost> createState() => _ReaderShellHostState();
}

class _ReaderShellHostState extends State<ReaderShellHost> {
  ReaderState get reader => widget.reader;
  SubtitleDisplay? _subtitles;
  (String, String)? _subtitleBook;
  @override
  void dispose() {
    _subtitles?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: reader.shellChanges,
    child: widget.child,
    builder: (context, child) {
      final enabled =
          reader.type == ComicType.local &&
          reader.preferences.read(ReaderPreferences.externalSubtitles);
      final book = enabled ? (App.dataPath, reader.cid) : null;
      if (book != _subtitleBook) {
        _subtitles?.dispose();
        _subtitleBook = book;
        _subtitles = book == null
            ? null
            : SubtitleDisplay(
                (chapter) => loadReadingSubtitles(
                  SubtitleStore('${book.$1}/comic-subtitles.db'),
                  book.$2,
                  chapter,
                ),
              );
      }
      return SubtitleScope(
        notifier: _subtitles,
        child: ReaderScaffold(
          key: reader.scaffoldKey,
          onRemoteKey: reader.onTvKeyEvent,
          onCancelRemoteKeys: () =>
              reader.imageViewController?.cancelKeyboardInput(),
          readBrightnessSettings: reader.readBrightnessSettings,
          brightnessChanges: appdata.settings,
          data: ReaderShellData(
            comicId: reader.cid,
            sourceKey: reader.type.sourceKey,
            title: reader.widget.name,
            chapterTitle: reader.widget.chapters?.titles.elementAtOrNull(
              reader.chapter - 1,
            ),
            hasChapters: reader.widget.chapters != null,
            vertical: reader.mode.isTopToBottom,
            gallery: reader.mode.isGallery,
            animating: reader.isPageAnimating,
            onCommentsPage: reader.isOnChapterCommentsPage,
            swipeToCollect:
                ReaderPreferences.quickCollectImage.normalize(
                  appdata.settings['quickCollectImage'],
                ) ==
                'Swipe',
            preferences: reader.preferences,
            automaticReading: reader.autoReading.status,
          ),
          progress: reader.createProgressRequest(),
          onExit: reader.requestExit,
          onDiagnostics: () => reader.openDiagnostics(),
          subtitleControls: _subtitles != null && reader.images != null
              ? ReaderSubtitleControls(
                  key: ObjectKey(_subtitles),
                  reader: reader,
                  display: _subtitles!,
                  store: SubtitleStore('${App.dataPath}/comic-subtitles.db'),
                )
              : null,
          onFullscreen: App.isDesktop ? reader.fullscreen : null,
          onToggleAutomaticReading: reader.toggleAutomaticReading,
          acquireSidebarPause: reader.acquireAutomaticReadingPause,
          readImagePickContext: reader.readImagePickContext,
          chapterNavigation: reader.chapterNavigation.action,
          imageWork: reader.imageWork,
          orientation: reader.readerOrientation,
          onRotate: App.isAndroid && !AppProfile.current.isTv
              ? reader.cycleReaderOrientation
              : null,
          onSystemUiChanged: reader.updateSystemUi,
          createChapterMenu: reader.createChapterMenu,
          favoriteChanges: reader.imageFavorites,
          createFavoriteQuery: reader.createImageFavoriteQuery,
          createImageFavorite: reader.createImageFavoriteRequest,
          createImageExport: reader.createImageExportRequest,
          createSettings: reader.createSettingsRequest,
          createChapterComments: reader.createChapterCommentsRequest,
          child: child!,
        ),
      );
    },
  );
}
