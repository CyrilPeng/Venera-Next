import 'parser.dart' show compareSemVer;
import 'source.dart';

/// Installed names and newer versions from one explicit source registry.
class ComicSourceSummarySnapshot {
  const ComicSourceSummarySnapshot._(this.names, this.availableUpdates);
  const ComicSourceSummarySnapshot.empty()
    : names = const [],
      availableUpdates = 0;

  final List<String> names;
  final int availableUpdates;

  factory ComicSourceSummarySnapshot.fromSources(
    Iterable<ComicSource> sources,
    Map<String, String> updates,
  ) {
    final installed = List<ComicSource>.of(sources);
    final versions = <String, String>{};
    for (final source in installed) {
      // The registry's find contract selects the first matching source.
      versions.putIfAbsent(source.key, () => source.version);
    }
    var count = 0;
    for (final update in updates.entries) {
      final current = versions[update.key];
      if (current != null && compareSemVer(update.value, current)) count++;
    }
    return ComicSourceSummarySnapshot._(
      List<String>.unmodifiable(installed.map((source) => source.name)),
      count,
    );
  }
}
