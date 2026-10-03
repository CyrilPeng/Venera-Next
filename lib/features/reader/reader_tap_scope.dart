import 'package:flutter/widgets.dart';

/// Gives descendants access only to their owning reader's tap suppression.
class ReaderTapScope extends InheritedWidget {
  const ReaderTapScope({
    super.key,
    required this.ignoreNextTap,
    required super.child,
  });

  final VoidCallback ignoreNextTap;

  static ReaderTapScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ReaderTapScope>();

  @override
  bool updateShouldNotify(ReaderTapScope oldWidget) =>
      ignoreNextTap != oldWidget.ignoreNextTap;
}
