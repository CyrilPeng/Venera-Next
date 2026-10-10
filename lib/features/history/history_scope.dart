import 'package:flutter/widgets.dart';

import 'history_manager.dart';
import 'image_favorites.dart';

/// The history store used by pages and reading sessions in this view.
class HistoryScope extends InheritedWidget {
  const HistoryScope({
    super.key,
    required this.manager,
    this.imageFavorites,
    required super.child,
  });

  final HistoryManager manager;
  final ImageFavoriteManager? imageFavorites;

  static HistoryManager read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<HistoryScope>()?.manager ??
      HistoryManager();

  static ImageFavoriteManager readImages(BuildContext context) =>
      context.getInheritedWidgetOfExactType<HistoryScope>()?.imageFavorites ??
      ImageFavoriteManager();

  @override
  bool updateShouldNotify(HistoryScope oldWidget) =>
      !identical(manager, oldWidget.manager) ||
      !identical(imageFavorites, oldWidget.imageFavorites);
}
