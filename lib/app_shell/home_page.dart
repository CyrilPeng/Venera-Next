import 'package:flutter/material.dart';
import 'package:venera_next/components/scroll.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/consts.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/follow_updates/follow_updates.dart';
import 'package:venera_next/features/image_favorites/image_favorites.dart';
import 'package:venera_next/features/search/search.dart';
import 'package:venera_next/features/sync/sync.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    var widget = SmoothCustomScrollView(
      slivers: [
        SliverPadding(padding: EdgeInsets.only(top: context.padding.top)),
        const SearchEntry(),
        const SyncStatusSummary(),
        const HistorySummary(),
        const LocalComicsSummary(),
        const FollowUpdatesWidget(),
        const ComicSourceSummary(),
        const ImageFavoritesSummary(),
        SliverPadding(padding: EdgeInsets.only(top: context.padding.bottom)),
      ],
    );
    return context.width > changePoint ? widget.paddingHorizontal(8) : widget;
  }
}
