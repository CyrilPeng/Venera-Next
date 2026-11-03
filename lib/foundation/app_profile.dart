import 'package:flutter/services.dart' show appFlavor;

/// Build identity is separate from the base version used by source scripts.
class AppProfile {
  const AppProfile({
    this.flavor = '',
    this.build = 'local',
    this.revision = 'uncommitted',
  });

  static const current = AppProfile(
    flavor: appFlavor ?? '',
    build: String.fromEnvironment('TV_BUILD', defaultValue: 'local'),
    revision: String.fromEnvironment(
      'TV_REVISION',
      defaultValue: 'uncommitted',
    ),
  );

  final String flavor;
  final String build;
  final String revision;

  bool get isTv => flavor == 'tv';
  String get applicationTitle => isTv ? 'VeneraNext TV' : 'VeneraNext';

  String displayVersion(String baseVersion) =>
      isTv ? '$baseVersion / TV $build / $revision' : baseVersion;
}
