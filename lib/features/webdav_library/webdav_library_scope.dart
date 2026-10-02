import 'package:flutter/widgets.dart';
import 'webdav_library_services.dart';

class WebDavLibraryScope extends InheritedWidget {
  const WebDavLibraryScope({
    super.key,
    required this.services,
    required super.child,
  });

  final WebDavLibraryServices services;

  static WebDavLibraryServices of(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<WebDavLibraryScope>();
    if (scope == null) throw StateError('WebDAV library scope is missing');
    return scope.services;
  }

  @override
  bool updateShouldNotify(WebDavLibraryScope oldWidget) =>
      !identical(services, oldWidget.services);
}
