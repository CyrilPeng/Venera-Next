import 'package:flutter/widgets.dart';

import 'source_installation.dart';

/// UI access to the application-owned queue; page disposal never owns it.
class SourceInstallationsScope extends InheritedWidget {
  const SourceInstallationsScope({
    super.key,
    required this.queue,
    required super.child,
  });

  final SourceInstallations queue;

  static SourceInstallations of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<SourceInstallationsScope>();
    if (scope == null) throw StateError('Missing source installation owner');
    return scope.queue;
  }

  @override
  bool updateShouldNotify(SourceInstallationsScope oldWidget) =>
      !identical(queue, oldWidget.queue);
}
