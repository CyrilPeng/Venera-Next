import 'package:flutter/material.dart';
import 'package:venera_next/foundation/app_page_route.dart';

/// Redirects the current route to a root page without popping a newer route.
bool replaceWithRootPage(BuildContext context, WidgetBuilder builder) {
  if (!context.mounted) return false;
  final origin = ModalRoute.of(context);
  if (origin == null || !origin.isCurrent) return false;
  final owner = origin.navigator;
  final root = Navigator.of(context, rootNavigator: true);
  root.push(AppPageRoute(builder: builder));
  if (owner != null &&
      owner.mounted &&
      origin.isActive &&
      (identical(owner, root) || !origin.isFirst)) {
    owner.removeRoute(origin);
  }
  return true;
}
