import 'package:venera_next/foundation/app_locale.dart';

import 'source.dart';

extension ComicSourceTranslation on String {
  /// Translate a string using specified comic source.
  String ts(String sourceKey) {
    var comicSource = ComicSource.find(sourceKey);
    if (comicSource == null || comicSource.translations == null) {
      return this;
    }
    var locale = appLocale;
    var lc = locale.languageCode;
    var cc = locale.countryCode;
    var key = "$lc${cc == null ? "" : "_$cc"}";
    return (comicSource.translations![key] ??
            comicSource.translations![lc])?[this] ??
        this;
  }
}
