import 'package:flutter/material.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_profile.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/reader_preferences.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'subtitles/mount_dialog.dart';
import 'subtitles/store.dart';
import 'reader_page.dart';
import 'scaffold.dart';
import 'shell_data.dart';

/// Widget composition is the only shell layer that knows the reader State.
/// Page reports rebuild the shell while retaining the content subtree.
class ReaderShellHost extends StatelessWidget {
  const ReaderShellHost({super.key, required this.reader, required this.child});
  final ReaderState reader;
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: reader.shellChanges,
    child: child,
    builder: (context, child) => ReaderScaffold(
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
      onSubtitles:
          reader.type == ComicType.local &&
              reader.images != null &&
              reader.preferences.read(ReaderPreferences.externalSubtitles)
          ? () {
              final book = reader.cid,
                  chapter = reader.eid,
                  path = App.dataPath;
              showDialog<bool>(
                context: context,
                builder: (_) => SubtitleMountDialog(
                  store: SubtitleStore('$path/comic-subtitles.db'),
                  book: book,
                  chapter: chapter,
                  images: List.of(reader.images ?? const []),
                  isCurrent: () =>
                      reader.mounted &&
                      reader.type == ComicType.local &&
                      reader.cid == book &&
                      reader.eid == chapter &&
                      App.dataPath == path,
                ),
              );
            }
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
}
