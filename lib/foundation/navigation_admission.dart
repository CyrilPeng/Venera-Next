import 'package:flutter/widgets.dart';

/// A mounted host decides whether UI navigation may start. The callback reads
/// the current lifetime even when an async action retained an older context.
class NavigationAdmission extends InheritedWidget {
  const NavigationAdmission({
    required this.allowsNavigation,
    required super.child,
    super.key,
  });

  final bool Function() allowsNavigation;

  static bool allows(BuildContext context) =>
      context.mounted &&
      (context
              .getInheritedWidgetOfExactType<NavigationAdmission>()
              ?.allowsNavigation() ??
          true);

  @override
  bool updateShouldNotify(NavigationAdmission oldWidget) => false;
}
