import 'webdav_library_settings.dart';
import 'webdav_library_source.dart';

/// Services supplied by the application owner to the settings UI.
class WebDavLibraryServices {
  const WebDavLibraryServices({required this.source, required this.settings});

  final WebDavLibrarySource source;
  final WebDavLibrarySettingsStore settings;
}
