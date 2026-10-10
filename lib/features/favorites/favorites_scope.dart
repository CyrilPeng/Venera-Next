import 'package:flutter/widgets.dart';

import 'favorites_manager.dart';

/// Supplies the library owned by this application view. Captured work retains
/// its original store while a replacement invalidates admission to that store.
class FavoritesScope extends StatefulWidget {
  const FavoritesScope({super.key, required this.manager, required this.child});

  final LocalFavoritesManager manager;
  final Widget child;

  static FavoriteStoreBinding capture(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<_FavoritesInherited>();
    if (scope != null) return scope.owner.capture();
    final manager = LocalFavoritesManager();
    return FavoriteStoreBinding._(manager, () => LocalFavoritesManager.cache);
  }

  static LocalFavoritesManager read(BuildContext context) =>
      capture(context).manager;

  @override
  State<FavoritesScope> createState() => _FavoritesScopeState();
}

class FavoriteStoreBinding {
  FavoriteStoreBinding._(this.manager, this._current);

  final LocalFavoritesManager manager;
  final LocalFavoritesManager? Function() _current;

  bool get isCurrent => identical(_current(), manager);
}

class _FavoritesScopeState extends State<FavoritesScope> {
  late LocalFavoritesManager _manager;

  FavoriteStoreBinding capture() =>
      FavoriteStoreBinding._(_manager, () => _manager);

  @override
  void initState() {
    super.initState();
    _manager = widget.manager;
  }

  @override
  void didUpdateWidget(FavoritesScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    _manager = widget.manager;
  }

  @override
  Widget build(BuildContext context) =>
      _FavoritesInherited(owner: this, child: widget.child);
}

class _FavoritesInherited extends InheritedWidget {
  const _FavoritesInherited({required this.owner, required super.child});

  final _FavoritesScopeState owner;

  @override
  bool updateShouldNotify(_FavoritesInherited oldWidget) => false;
}
