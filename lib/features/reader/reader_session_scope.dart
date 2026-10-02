import 'package:flutter/widgets.dart';

/// Supplies the application's completion callback to reader entry routes.
class ReaderSessionScope extends InheritedWidget {
  const ReaderSessionScope({
    super.key,
    required this.onClosed,
    required super.child,
  });

  final VoidCallback onClosed;

  static VoidCallback onClosedOf(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<ReaderSessionScope>();
    if (scope == null) throw StateError('Reader session scope is missing');
    return scope.onClosed;
  }

  @override
  bool updateShouldNotify(ReaderSessionScope oldWidget) =>
      onClosed != oldWidget.onClosed;
}
