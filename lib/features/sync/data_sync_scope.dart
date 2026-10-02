import 'package:flutter/widgets.dart';
import 'data_sync_controller.dart';

/// Supplies a controller owned by the application; this scope never disposes it.
class DataSyncScope extends InheritedWidget {
  const DataSyncScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final DataSyncController controller;

  static DataSyncController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<DataSyncScope>();
    if (scope == null) throw StateError('Data sync scope is missing');
    return scope.controller;
  }

  @override
  bool updateShouldNotify(DataSyncScope oldWidget) =>
      !identical(controller, oldWidget.controller);
}
