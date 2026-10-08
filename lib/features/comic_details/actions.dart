import 'package:venera_next/foundation/global_preference_store.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/components/menu.dart';
import 'package:venera_next/components/side_bar.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/features/comic_details/archive_download_dialog.dart';
import 'package:venera_next/features/comic_details/comments_page.dart';
import 'package:venera_next/features/comic_details/favorite.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/reader/reader.dart';
import 'package:venera_next/features/search/search_shortcut.dart';
import 'package:venera_next/features/search/search_shortcuts.dart';
import 'package:venera_next/routing/app_navigation.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/routing/page_jump_target.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/features/comic_details/rating_dialog.dart';

abstract mixin class ComicPageActions {
  void update();

  BuildContext get context;

  MenuRouteController get contextMenus;

  bool isComicActive(ComicDetails value);

  ComicDetails get comic;

  ComicSource get comicSource => ComicSource.find(comic.sourceKey)!;

  History? get history;

  ComicDetails? _likingComic;

  bool get isLiking => _likingComic != null && isComicActive(_likingComic!);

  bool isLiked = false;

  Future<void> likeOrUnlike() async {
    if (isLiking) return;
    final target = comic;
    final wasLiked = isLiked;
    _likingComic = target;
    update();
    Res<bool> result;
    try {
      result = await comicSource.likeOrUnlikeComic!(target.id, wasLiked);
    } catch (error, stack) {
      result = Res.fromException(error, stack);
    } finally {
      if (identical(_likingComic, target)) _likingComic = null;
    }
    if (!isComicActive(target)) return;
    if (result.error) {
      final currentContext = context;
      if (currentContext.mounted) {
        currentContext.showMessage(message: result.errorMessage!);
      }
    } else {
      isLiked = !wasLiked;
    }
    update();
  }

  /// whether the comic is added to local favorite
  bool isAddToLocalFav = false;

  /// whether the comic is favorite on the server
  bool isFavorite = false;

  FavoriteItem _toFavoriteItem() {
    var tags = <String>[];
    for (var e in comic.tags.entries) {
      tags.addAll(e.value.map((tag) => '${e.key}:$tag'));
    }
    return FavoriteItem(
      id: comic.id,
      name: comic.title,
      coverPath: comic.cover,
      author: comic.subTitle ?? comic.uploader ?? '',
      type: comic.comicType,
      tags: tags,
    );
  }

  void openFavPanel() {
    final target = comic;
    final owner = context;
    showSideBar(
      appNavigation.rootContext,
      ComicFavoritePanel(
        cid: comic.id,
        type: comic.comicType,
        isFavorite: isFavorite,
        onFavorite: (local, network) {
          if (!owner.mounted || !isComicActive(target)) return;
          if (network != null) {
            isFavorite = network;
          }
          if (local != null) {
            isAddToLocalFav = local;
          }
          update();
        },
        favoriteItem: _toFavoriteItem(),
        updateTime: comic.findUpdateTime(),
      ),
    );
  }

  ComicDetails? _addingQuickFavorite;

  Future<void> quickFavorite() async {
    if (_addingQuickFavorite != null) return;
    var folder = GlobalPreferenceStore(
      appdata.settings,
    ).read(FavoritePreferences.quickFavorite);
    if (folder == null) {
      return;
    }
    final owner = context;
    final target = comic;
    final item = _toFavoriteItem();
    final updateTime = target.findUpdateTime();
    final manager = LocalFavoritesManager();
    final generation = manager.connectionGeneration;
    _addingQuickFavorite = target;
    try {
      await AppDataOperations.instance.access(() async {
        if (!owner.mounted || !isComicActive(target)) return;
        if (manager.connectionGeneration != generation) {
          throw StateError('Favorites database changed. Try again.');
        }
        await manager.addComic(folder, item, null, updateTime);
      });
      if (!owner.mounted || !isComicActive(target)) return;
      isAddToLocalFav = true;
      update();
      owner.showMessage(
        message: 'Added to @folder'.tlParams({'folder': folder}),
      );
    } catch (error, stack) {
      Log.error('Quick favorite', error, stack);
      if (owner.mounted && isComicActive(target)) {
        owner.showMessage(message: error.toString());
      }
    } finally {
      if (identical(_addingQuickFavorite, target)) _addingQuickFavorite = null;
    }
  }

  Widget buildReadLaterAction() => ReadLaterButton(
    comic: _toFavoriteItem(),
    onChanged: () {
      isAddToLocalFav = LocalFavoritesManager().isExist(
        comic.id,
        comic.comicType,
      );
      update();
    },
  );

  Future<void>? _sharing;

  Future<void> share() {
    if (_sharing case final pending?) return pending;
    final owner = context;
    if (!NavigationAdmission.allows(owner)) return Future.value();
    final target = comic;
    final route = ModalRoute.of(owner);
    bool isCurrentOwner() =>
        owner.mounted &&
        isComicActive(target) &&
        route?.isCurrent != false &&
        identical(ModalRoute.of(owner), route);
    final text =
        '${target.title}${target.url == null ? '' : '\n${target.url}'}';
    final window = owner.getInheritedWidgetOfExactType<WindowFrameController>();
    final operation = () async {
      try {
        await Share.shareText(
          text,
          resolveOrigin: () => owner.sharePositionOrigin,
          canShare: () =>
              isCurrentOwner() &&
              window?.isClosing != true &&
              NavigationAdmission.allows(owner),
        );
      } catch (error, stack) {
        Log.error('Share', error, stack);
        if (owner.mounted && isCurrentOwner() && window?.isClosing != true) {
          owner.showMessage(message: 'Error'.tl);
        } else {
          Error.throwWithStackTrace(error, stack);
        }
      }
    }();
    _sharing = operation;
    // Queued requests check admission again before opening native UI. Once
    // dispatched, the window must join acknowledgment even after page removal.
    window?.trackExitTask(operation);
    unawaited(
      operation.then<void>(
        (_) {
          if (identical(_sharing, operation)) _sharing = null;
        },
        onError: (Object _, StackTrace _) {
          if (identical(_sharing, operation)) _sharing = null;
        },
      ),
    );
    return operation;
  }

  /// read the comic
  ///
  /// [ep] the episode number, start from 1
  ///
  /// [page] the page number, start from 1
  ///
  /// [group] the chapter group number, start from 1
  void read([int? ep, int? page, int? group]) {
    appNavigation.rootContext
        .to(
          () => Reader(
            onClosed: ReaderSessionScope.onClosedOf(appNavigation.rootContext),
            type: comic.comicType,
            cid: comic.id,
            name: comic.title,
            chapters: comic.chapters,
            initialChapter: ep,
            initialPage: page,
            initialChapterGroup: group,
            history: history ?? History.fromModel(model: comic, ep: 0, page: 0),
            author: comic.findAuthor() ?? '',
            tags: comic.plainTags,
          ),
        )
        .then((_) {
          onReadEnd();
        });
  }

  void continueRead() {
    var ep = history?.ep ?? 1;
    var page = history?.page ?? 1;
    var group = history?.group ?? 1;
    read(ep, page, group);
  }

  void onReadEnd();

  bool _choosingDownload = false;

  Future<void> download() async {
    if (_choosingDownload) return;
    final target = comic;
    final source = comicSource;
    final owner = context;
    final library = LocalManager();
    _choosingDownload = true;
    try {
      if (library.isDownloading(target.id, target.comicType)) {
        owner.showMessage(message: "The comic is downloading".tl);
        return;
      }
      if (target.chapters == null &&
          library.isDownloaded(target.id, target.comicType, 0)) {
        owner.showMessage(message: "The comic is downloaded".tl);
        return;
      }

      if (source.archiveDownloader != null) {
        final selection = await showDialog<ArchiveDownloadSelection>(
          context: owner,
          builder: (_) => ArchiveDownloadDialog(
            downloader: source.archiveDownloader!,
            comicId: target.id,
          ),
        );
        if (!owner.mounted || !isComicActive(target) || selection == null) {
          return;
        }
        if (selection.url != null) {
          if (library.isDownloading(target.id, target.comicType)) return;
          library.addTask(
            ArchiveDownloadTask(selection.url!, target, storage: library),
          );
          owner.showMessage(message: "Download started".tl);
          update();
          return;
        }
      }

      if (!owner.mounted || !isComicActive(target)) return;
      if (library.isDownloading(target.id, target.comicType)) return;
      if (target.chapters == null) {
        library.addTask(
          ImagesDownloadTask(
            storage: library,
            source: source,
            comicId: target.id,
            comic: target,
          ),
        );
      } else {
        List<int>? selected;
        var downloaded = <int>[];
        var localComic = library.find(target.id, target.comicType);
        if (localComic != null) {
          for (int i = 0; i < target.chapters!.length; i++) {
            if (localComic.downloadedChapters.contains(
              target.chapters!.ids.elementAt(i),
            )) {
              downloaded.add(i);
            }
          }
        }
        await showSideBar(
          owner,
          _SelectDownloadChapter(
            target.chapters!.titles.toList(),
            (v) => selected = v,
            downloaded,
          ),
        );
        if (!owner.mounted || !isComicActive(target) || selected == null) {
          return;
        }
        if (library.isDownloading(target.id, target.comicType)) return;
        library.addTask(
          ImagesDownloadTask(
            storage: library,
            source: source,
            comicId: target.id,
            comic: target,
            chapters: selected!.map((i) {
              return target.chapters!.ids.elementAt(i);
            }).toList(),
          ),
        );
      }
      owner.showMessage(message: "Download started".tl);
      update();
    } catch (error) {
      if (owner.mounted && isComicActive(target)) {
        owner.showMessage(message: error.toString());
      }
    } finally {
      _choosingDownload = false;
    }
  }

  void onTapTag(String tag, String namespace) {
    var target = searchTargetForTag(tag, namespace);
    var context = appNavigation.mainNavigatorKey!.currentContext!;
    target?.jump(context);
  }

  PageJumpTarget? searchTargetForTag(String tag, String namespace) {
    return comicSource.handleClickTagEvent?.call(namespace, tag);
  }

  void onLongPressTag(String tag, String namespace, BuildContext tagContext) {
    final target = comic;
    final renderBox = tagContext.findRenderObject() as RenderBox;
    final offset = renderBox.localToGlobal(Offset.zero);
    final shortcut = searchTargetForTag(tag, namespace) == null
        ? null
        : SearchShortcut(
            kind: isAuthorNamespace(namespace)
                ? SearchShortcutKind.author
                : SearchShortcutKind.tag,
            sourceKey: comic.sourceKey,
            namespace: namespace,
            value: tag,
          );
    showSearchShortcutMenu(
      menus: contextMenus,
      isValid: () => isComicActive(target),
      context: tagContext,
      location: Offset(
        offset.dx + renderBox.size.width / 2 - 121,
        offset.dy + renderBox.size.height - 8,
      ),
      copyText: tag,
      shortcut: shortcut,
    );
  }

  void showMoreActions() {
    final target = comic;
    contextMenus.show(
      context,
      Offset(context.width - 16, context.padding.top),
      [
        MenuEntry(
          icon: Icons.copy,
          text: "Copy Title".tl,
          onClick: () {
            Clipboard.setData(ClipboardData(text: target.title));
            context.showMessage(message: "Copied".tl);
          },
        ),
        MenuEntry(
          icon: Icons.copy_rounded,
          text: "Copy ID".tl,
          onClick: () {
            Clipboard.setData(ClipboardData(text: target.id));
            context.showMessage(message: "Copied".tl);
          },
        ),
        if (target.url != null)
          MenuEntry(
            icon: Icons.link,
            text: "Copy URL".tl,
            onClick: () {
              Clipboard.setData(ClipboardData(text: target.url!));
              context.showMessage(message: "Copied".tl);
            },
          ),
        if (target.url != null)
          MenuEntry(
            icon: Icons.open_in_browser,
            text: "Open in Browser".tl,
            onClick: () {
              launchUrlString(target.url!);
            },
          ),
      ],
      isValid: () => isComicActive(target),
    );
  }

  void showComments() {
    showSideBar(
      appNavigation.rootContext,
      CommentsPage(data: comic, source: comicSource),
    );
  }

  void starRating() {
    final source = comicSource;
    if (!source.isLogged) return;
    final id = comic.id;
    showDialog<void>(
      context: context,
      builder: (_) => ComicRatingDialog(
        submit: (rating) => source.starRatingFunc!(id, rating),
      ),
    );
  }
}

class _SelectDownloadChapter extends StatefulWidget {
  const _SelectDownloadChapter(this.eps, this.finishSelect, this.downloadedEps);

  final List<String> eps;
  final void Function(List<int>) finishSelect;
  final List<int> downloadedEps;

  @override
  State<_SelectDownloadChapter> createState() => _SelectDownloadChapterState();
}

class _SelectDownloadChapterState extends State<_SelectDownloadChapter> {
  List<int> selected = [];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: Text("Download".tl),
        backgroundColor: context.colorScheme.surfaceContainerLow,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: widget.eps.length,
              itemBuilder: (context, i) {
                return CheckboxListTile(
                  title: Text(widget.eps[i]),
                  value:
                      selected.contains(i) || widget.downloadedEps.contains(i),
                  onChanged: widget.downloadedEps.contains(i)
                      ? null
                      : (v) {
                          setState(() {
                            if (selected.contains(i)) {
                              selected.remove(i);
                            } else {
                              selected.add(i);
                            }
                          });
                        },
                );
              },
            ),
          ),
          Container(
            height: 50,
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: context.colorScheme.outlineVariant),
              ),
            ),
            child: Row(
              children: [
                const SizedBox(width: 16),
                Expanded(
                  child: TextButton(
                    onPressed: () {
                      var res = <int>[];
                      for (int i = 0; i < widget.eps.length; i++) {
                        if (!widget.downloadedEps.contains(i)) {
                          res.add(i);
                        }
                      }
                      widget.finishSelect(res);
                      context.pop();
                    },
                    child: Text("Download All".tl),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: FilledButton(
                    onPressed: selected.isEmpty
                        ? null
                        : () {
                            widget.finishSelect(selected);
                            context.pop();
                          },
                    child: Text("Download Selected".tl),
                  ),
                ),
                const SizedBox(width: 16),
              ],
            ),
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }
}
