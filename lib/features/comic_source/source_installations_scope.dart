import 'package:flutter/widgets.dart';

import 'source_installation.dart';
import 'source_update_service.dart';

/// UI access to the application-owned queue; page disposal never owns it.
class SourceInstallationsScope extends InheritedWidget {
  const SourceInstallationsScope({
    super.key,
    required this.queue,
    this.updates,
    this.refresh,
    required super.child,
  });

  final SourceInstallations queue;
  final SourceUpdateService? updates;
  final VoidCallback? refresh;

  static SourceInstallations of(BuildContext context) => ownerOf(context).queue;

  static SourceInstallationsScope ownerOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<SourceInstallationsScope>();
    if (scope == null) throw StateError('Missing source installation owner');
    return scope;
  }

  @override
  bool updateShouldNotify(SourceInstallationsScope oldWidget) =>
      !identical(queue, oldWidget.queue) ||
      !identical(updates, oldWidget.updates) ||
      refresh != oldWidget.refresh;
}
