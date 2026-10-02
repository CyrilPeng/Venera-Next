import 'package:venera_next/features/webdav_library/webdav_library_api.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';

WebDavLibraryServices? _library;

/// Replace callbacks from a previous app mount with this owner's instance.
void mountWebDavLibrary(WebDavLibraryServices services) {
  final manager = ComicSourceManager();
  manager.remove(WebDavLibrarySource.sourceKey);
  if (services.settings.read().connection.isValid) {
    manager.add(services.source.create());
  }
}

/// Core startup and the mounted UI share this application-owned instance.
/// The feature itself has no default singleton or global test reset.
WebDavLibraryServices get webDavLibrary {
  final current = _library;
  if (current != null && !current.source.isDisposed) return current;
  late WebDavLibrarySource source;
  final settings = WebDavLibrarySettingsStore(
    readValue: (key) => appdata.settings[key],
    persist: (values) async {
      for (final entry in values.entries) {
        appdata.settings[entry.key] = entry.value;
      }
      await appdata.saveData(false);
    },
    onConnectionChanged: (previous) => source.onConfigurationChanged(previous),
  );
  source = WebDavLibrarySource(
    readSettings: settings.read,
    cache: WebDavLibraryCache('${App.dataPath}/webdav_library.db'),
  );
  return _library = WebDavLibraryServices(source: source, settings: settings);
}
