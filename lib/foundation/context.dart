import 'package:flutter/material.dart';

import 'app_page_route.dart';
import 'navigation_admission.dart';

void Function(BuildContext context, String message)? _showMessageHandler;

void registerShowMessageHandler(
  void Function(BuildContext context, String message) handler,
) {
  _showMessageHandler = handler;
}

extension Navigation on BuildContext {
  /// Capture the visible source rectangle before an asynchronous share starts.
  /// iPad rejects an empty popover origin or one outside its Flutter view.
  Rect get sharePositionOrigin {
    if (!mounted) throw StateError('Share source is no longer mounted');
    final render = findRenderObject();
    if (render is! RenderBox || !render.attached || !render.hasSize) {
      throw StateError('Share source has no active layout');
    }
    final view = View.of(this);
    final viewport = Offset.zero & (view.physicalSize / view.devicePixelRatio);
    final origin = (render.localToGlobal(Offset.zero) & render.size).intersect(
      viewport,
    );
    if (origin.isEmpty || !origin.isFinite) {
      throw StateError('Share source is outside the current view');
    }
    return origin;
  }

  void pop<T>([T? result]) {
    if (NavigationAdmission.allows(this)) {
      Navigator.of(this).pop(result);
    }
  }

  bool canPop() {
    return Navigator.of(this).canPop();
  }

  Future<T?> to<T>(Widget Function() builder) {
    if (!NavigationAdmission.allows(this)) return Future.value();
    return Navigator.of(
      this,
    ).push<T>(AppPageRoute(builder: (context) => builder()));
  }

  Future<void> toReplacement<T>(Widget Function() builder) {
    if (!NavigationAdmission.allows(this)) return Future.value();
    return Navigator.of(
      this,
    ).pushReplacement(AppPageRoute(builder: (context) => builder()));
  }

  double get width => MediaQuery.of(this).size.width;

  double get height => MediaQuery.of(this).size.height;

  EdgeInsets get padding => MediaQuery.of(this).padding;

  EdgeInsets get viewInsets => MediaQuery.of(this).viewInsets;

  ColorScheme get colorScheme => Theme.of(this).colorScheme;

  Brightness get brightness => Theme.of(this).brightness;

  bool get isDarkMode => brightness == Brightness.dark;

  void showMessage({required String message}) {
    _showMessageHandler?.call(this, message);
  }

  Color useBackgroundColor(MaterialColor color) {
    return color[brightness == Brightness.light ? 100 : 800]!;
  }

  Color useTextColor(MaterialColor color) {
    return color[brightness == Brightness.light ? 800 : 100]!;
  }
}
