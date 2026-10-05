import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/global_preference_store.dart';

/// The core owns the live cache effect. UI writes, imports and restoration all
/// use the same settings notification; a late form never opens a new cache.
class CacheSettingsBinding {
  CacheSettingsBinding(this.settings, this.cache) {
    _update();
    settings.addListener(_update);
  }
  final Settings settings;
  final CacheManager cache;
  bool _disposed = false;
  int? _limit;

  void _update() {
    if (_disposed || cache.isClosing) return;
    final limit = GlobalPreferenceStore(
      settings,
    ).read(AppPreferences.cacheSize).toInt();
    if (_limit == limit) return;
    cache.setLimitSize(limit);
    _limit = limit;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    settings.removeListener(_update);
  }
}
