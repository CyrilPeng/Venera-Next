import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera_next/foundation/navigation_admission.dart';

/// One mounted UI owner retains its pending/open context menu.
class MenuRouteController {
  MenuRouteController({this.ownerIdentity});
  final Object? Function()? ownerIdentity;
  _MenuOperation? _active;
  bool _disposed = false;
  int _generation = 0;

  ContextMenuHandle? show(
    BuildContext context,
    Offset location,
    List<MenuEntry> entries, {
    bool Function()? isValid,
    Listenable? changes,
  }) {
    if (_disposed || entries.isEmpty || !NavigationAdmission.allows(context)) {
      return null;
    }
    final parents = <ModalRoute<dynamic>>[];
    var parent = ModalRoute.of(context);
    while (parent != null && !parents.contains(parent)) {
      parents.add(parent);
      final navigationContext = parent.navigator?.context;
      parent = navigationContext == null
          ? null
          : ModalRoute.of(navigationContext);
    }
    final identity = ownerIdentity?.call();
    bool ownerAlive() =>
        context.mounted &&
        (ownerIdentity == null || ownerIdentity!() == identity) &&
        parents.every((route) => route.isActive) &&
        NavigationAdmission.allows(context) &&
        (isValid?.call() ?? true);
    if (!ownerAlive() ||
        (!parents.every((route) => route.isCurrent) &&
            _active?.route?.isCurrent != true)) {
      return null;
    }
    final navigator = Navigator.of(context, rootNavigator: true);
    final overlayBox =
        navigator.overlay!.context.findRenderObject()! as RenderBox;
    final position = overlayBox.globalToLocal(location);
    final theme = InheritedTheme.capture(from: context, to: navigator.context);
    final items = List<MenuEntry>.unmodifiable(entries);
    final dismissLabel = MaterialLocalizations.of(
      context,
    ).modalBarrierDismissLabel;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 200);
    close();
    final generation = _generation;
    final operation = _active = _MenuOperation();
    bool alive() => !operation.closed && !_disposed && ownerAlive();
    void check() {
      if (!alive()) _close(operation);
    }

    operation.check = check;
    operation.changes = changes;
    changes?.addListener(check);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!alive() ||
          !navigator.mounted ||
          !parents.every((route) => route.isCurrent)) {
        _close(operation);
        return;
      }
      final route = _ContextMenuRoute(
        position: position,
        entries: items,
        dismissLabel: dismissLabel,
        theme: theme,
        duration: duration,
        canSelect: alive,
        onSelect: (entry) {
          if (!alive() || operation.route?.isCurrent != true) return;
          // Retire before popping: callbacks/observers can reenter the owner.
          _finish(operation);
          navigator.pop();
          if (!_disposed &&
              generation == _generation &&
              ownerAlive() &&
              parents.every((route) => route.isCurrent)) {
            entry.onClick();
          }
        },
      );
      operation.route = route;
      operation.navigator = navigator;
      navigator.push<void>(route).then((_) => _finish(operation));
    });
    WidgetsBinding.instance.ensureVisualUpdate();
    return ContextMenuHandle._(
      () => _close(operation),
      () => !operation.closed && operation.route?.isCurrent == true,
    );
  }

  /// Called when owner state changes without replacing its widget.
  void revalidate() => _active?.check?.call();

  void _finish(_MenuOperation operation) {
    if (operation.closed) return;
    operation.closed = true;
    final check = operation.check;
    if (check != null) operation.changes?.removeListener(check);
    operation.check = null;
    operation.changes = null;
    operation.route = null;
    operation.navigator = null;
    if (identical(_active, operation)) _active = null;
  }

  void _close(_MenuOperation operation) {
    if (operation.closed) return;
    final navigator = operation.navigator, route = operation.route;
    _finish(operation);
    // Deactivation and target notifications can run while Navigator is locked.
    scheduleMicrotask(() {
      if (navigator != null &&
          navigator.mounted &&
          route != null &&
          route.isActive) {
        navigator.removeRoute(route);
      }
    });
  }

  void close() {
    _generation++;
    final operation = _active;
    if (operation != null) _close(operation);
  }

  void dispose() {
    _disposed = true;
    close();
  }
}

class _MenuOperation {
  bool closed = false;
  _ContextMenuRoute? route;
  NavigatorState? navigator;
  VoidCallback? check;
  Listenable? changes;
}

class ContextMenuHandle {
  const ContextMenuHandle._(this.close, this._isCurrent);
  final VoidCallback close;
  final bool Function() _isCurrent;
  bool get isCurrent => _isCurrent();
}

/// State-based owners dispose menus even when the enclosing route survives.
mixin ContextMenuOwner<T extends StatefulWidget> on State<T> {
  Object? get contextMenuIdentity => widget;
  late final contextMenus = MenuRouteController(
    ownerIdentity: () => contextMenuIdentity,
  );
  @override
  void didUpdateWidget(covariant T oldWidget) {
    super.didUpdateWidget(oldWidget);
    contextMenus.revalidate();
  }

  @override
  void deactivate() {
    contextMenus.close();
    super.deactivate();
  }

  @override
  void dispose() {
    contextMenus.dispose();
    super.dispose();
  }
}

/// A local lifecycle boundary for stateless cards and individual list rows.
class ContextMenuRegion extends StatefulWidget {
  const ContextMenuRegion({
    required this.identity,
    required this.builder,
    super.key,
  });
  final Object? identity;
  final Widget Function(BuildContext context, MenuRouteController menus)
  builder;
  static MenuRouteController of(BuildContext context) =>
      context.findAncestorStateOfType<_ContextMenuRegionState>()!.contextMenus;
  @override
  State<ContextMenuRegion> createState() => _ContextMenuRegionState();
}

class _ContextMenuRegionState extends State<ContextMenuRegion>
    with ContextMenuOwner {
  @override
  Object? get contextMenuIdentity => widget.identity;
  @override
  Widget build(BuildContext context) =>
      Builder(builder: (context) => widget.builder(context, contextMenus));
}

class _ContextMenuRoute extends PopupRoute<void> {
  _ContextMenuRoute({
    required this.position,
    required this.entries,
    required this.theme,
    required this.duration,
    required this.canSelect,
    required this.onSelect,
    required this.dismissLabel,
  });
  final String dismissLabel;
  final Offset position;
  final List<MenuEntry> entries;
  final CapturedThemes theme;
  final Duration duration;
  final bool Function() canSelect;
  final ValueChanged<MenuEntry> onSelect;
  @override
  Color? get barrierColor => Colors.transparent;
  @override
  bool get barrierDismissible => true;
  @override
  String get barrierLabel => dismissLabel;
  @override
  Duration get transitionDuration => duration;
  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final media = MediaQuery.of(context);
    final inset = EdgeInsets.fromLTRB(
      math.max(media.padding.left, media.viewInsets.left) + 8,
      math.max(media.padding.top, media.viewInsets.top) + 8,
      math.max(media.padding.right, media.viewInsets.right) + 8,
      math.max(media.padding.bottom, media.viewInsets.bottom) + 8,
    );
    return theme.wrap(
      CustomSingleChildLayout(
        delegate: _MenuLayout(
          position,
          inset,
          entries.any((e) => e.icon != null) ? 242 : 216,
        ),
        child: _MenuContents(
          entries: entries,
          onSelect: (entry) {
            if (isCurrent && canSelect()) onSelect(entry);
          },
          onDismiss: () {
            if (isCurrent) navigator?.pop();
          },
        ),
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => FadeTransition(opacity: animation, child: child);
}

class _MenuLayout extends SingleChildLayoutDelegate {
  const _MenuLayout(this.position, this.insets, this.width);
  final Offset position;
  final EdgeInsets insets;
  final double width;
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: math.max(
          0,
          math.min(width, constraints.maxWidth - insets.horizontal),
        ),
        maxHeight: math.max(0, constraints.maxHeight - insets.vertical),
      );
  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    position.dx.clamp(
      math.min(insets.left, size.width),
      math.max(
        math.min(insets.left, size.width),
        size.width - insets.right - childSize.width,
      ),
    ),
    position.dy.clamp(
      math.min(insets.top, size.height),
      math.max(
        math.min(insets.top, size.height),
        size.height - insets.bottom - childSize.height,
      ),
    ),
  );
  @override
  bool shouldRelayout(_MenuLayout oldDelegate) =>
      position != oldDelegate.position ||
      insets != oldDelegate.insets ||
      width != oldDelegate.width;
}

class _MenuContents extends StatefulWidget {
  const _MenuContents({
    required this.entries,
    required this.onSelect,
    required this.onDismiss,
  });
  final List<MenuEntry> entries;
  final ValueChanged<MenuEntry> onSelect;
  final VoidCallback onDismiss;
  @override
  State<_MenuContents> createState() => _MenuContentsState();
}

class _MenuContentsState extends State<_MenuContents> {
  late final _focus = List.generate(widget.entries.length, (_) => FocusNode());
  final _scroll = ScrollController();
  @override
  void dispose() {
    for (final node in _focus) {
      node.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    scopesRoute: true,
    namesRoute: true,
    explicitChildNodes: true,
    label: MaterialLocalizations.of(context).popupMenuLabel,
    child: CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onDismiss,
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            FocusScope.of(context).nextFocus(),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            FocusScope.of(context).previousFocus(),
        const SingleActivator(LogicalKeyboardKey.home): () =>
            _focus.first.requestFocus(),
        const SingleActivator(LogicalKeyboardKey.end): () =>
            _focus.last.requestFocus(),
      },
      child: Material(
        elevation: 8,
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(4),
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < widget.entries.length; i++)
                Builder(
                  builder: (context) {
                    final entry = widget.entries[i];
                    return Semantics(
                      button: true,
                      child: InkWell(
                        focusNode: _focus[i],
                        autofocus: i == 0,
                        onFocusChange: (focused) {
                          if (focused) {
                            Scrollable.ensureVisible(
                              context,
                              alignmentPolicy:
                                  ScrollPositionAlignmentPolicy.explicit,
                            );
                          }
                        },
                        borderRadius: BorderRadius.circular(4),
                        onTap: () => widget.onSelect(entry),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (entry.icon != null) ...[
                                  ExcludeSemantics(
                                    child: Icon(
                                      entry.icon,
                                      size: 18,
                                      color: entry.color,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                ],
                                Expanded(
                                  child: Text(
                                    entry.text,
                                    style: TextStyle(color: entry.color),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class MenuEntry {
  MenuEntry({required this.text, this.icon, this.color, required this.onClick});
  final String text;
  final IconData? icon;
  final Color? color;
  final VoidCallback onClick;
}
