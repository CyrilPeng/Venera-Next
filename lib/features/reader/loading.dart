import 'reader_session_scope.dart';
import 'reader_entry_loader.dart';
import 'package:venera_next/network/request_scope.dart';
import 'package:flutter/material.dart';
import 'package:venera_next/components/loading.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/history/history_manager.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/features/reader/reader_page.dart';
import 'package:venera_next/foundation/res.dart';

class ReaderWithLoading extends StatefulWidget {
  const ReaderWithLoading({
    super.key,
    required this.id,
    required this.sourceKey,
    this.initialEp,
    this.initialPage,
  });

  final String id;

  final String sourceKey;

  final int? initialEp;

  final int? initialPage;

  @override
  State<ReaderWithLoading> createState() => _ReaderWithLoadingState();
}

class _ReaderWithLoadingState
    extends LoadingState<ReaderWithLoading, ReaderProps> {
  final _entryLoader = ReaderEntryLoader(
    resolveComicLoader: (key) {
      final source = ComicSource.find(key);
      // Keep an installed source with a missing capability distinct from a
      // missing source; its original failure must not trigger local fallback.
      return source == null ? null : (id) => source.loadComicInfo!(id);
    },
    findHistory: (id, type) => HistoryManager().find(id, type),
    findLocalComic: (id, type) => LocalManager().find(id, type),
  );

  @override
  void didUpdateWidget(ReaderWithLoading oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id || oldWidget.sourceKey != widget.sourceKey) {
      retry();
    }
  }

  @override
  Widget buildContent(BuildContext context, ReaderProps data) {
    return Reader(
      onClosed: ReaderSessionScope.onClosedOf(context),
      type: data.type,
      cid: data.cid,
      name: data.name,
      chapters: data.chapters,
      history: data.history,
      initialChapter: widget.initialEp ?? data.history.ep,
      initialPage: widget.initialPage ?? data.history.page,
      initialChapterGroup: data.history.group,
      author: data.author,
      tags: data.tags,
    );
  }

  @override
  Future<Res<ReaderProps>> loadData(RequestScope scope) => _entryLoader.load(
    id: widget.id,
    sourceKey: widget.sourceKey,
    scope: scope,
  );
}
