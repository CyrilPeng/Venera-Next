import 'package:flutter/foundation.dart';
import 'package:venera_next/foundation/appdata.dart';

import 'search_shortcut.dart';

class SearchShortcutManager extends ChangeNotifier {
  SearchShortcutManager._() {
    appdata.settings.addListener(_onSettingsChanged);
  }

  static final instance = SearchShortcutManager._();

  List<SearchShortcut> get all => _read(appdata.settings);

  List<SearchShortcut> _read(Settings settings) {
    final raw = settings['searchShortcuts'];
    if (raw is! List) return const [];
    return raw
        .map(SearchShortcut.fromJson)
        .whereType<SearchShortcut>()
        .toList(growable: false);
  }

  bool contains(SearchShortcut shortcut) {
    return all.any((item) => item.identity == shortcut.identity);
  }

  Future<void> add(SearchShortcut shortcut) => appdata.updateSettings((
    settings,
  ) {
    final items = _read(settings).toList();
    if (items.any((item) => item.identity == shortcut.identity)) return;
    items.add(shortcut);
    settings['searchShortcuts'] = items.map((item) => item.toJson()).toList();
  });

  Future<void> remove(SearchShortcut shortcut) =>
      appdata.updateSettings((settings) {
        final items = _read(settings)
            .where((item) => item.identity != shortcut.identity)
            .map((item) => item.toJson())
            .toList();
        settings['searchShortcuts'] = items;
      });

  void _onSettingsChanged() {
    notifyListeners();
  }
}
