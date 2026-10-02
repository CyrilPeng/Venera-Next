import 'package:flutter/widgets.dart';
import 'follow_updates_runtime.dart';

/// Supplies the application's runtime without taking ownership of it.
class FollowUpdatesScope extends InheritedWidget {
  const FollowUpdatesScope({
    super.key,
    required this.runtime,
    required super.child,
  });

  final FollowUpdatesRuntime runtime;

  static FollowUpdatesRuntime of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<FollowUpdatesScope>();
    if (scope == null) throw StateError('Follow updates scope is missing');
    return scope.runtime;
  }

  @override
  bool updateShouldNotify(FollowUpdatesScope oldWidget) =>
      !identical(runtime, oldWidget.runtime);
}
