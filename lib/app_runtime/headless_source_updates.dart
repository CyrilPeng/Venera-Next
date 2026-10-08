import 'package:venera_next/features/comic_source/comic_source_api.dart';

import 'headless_source_update_command.dart';

/// Adapt the accepted check itself; mutable registry summaries are only UI
/// notifications and cannot identify this command's update targets.
Future<HeadlessSourceUpdateCheck> checkSourceUpdatesForCli(
  SourceUpdateService service,
) async {
  final result = await service.checkUpdates();
  return HeadlessSourceUpdateCheck(
    failures: result.failures.map((failure) => failure.toString()).toList(),
    updates: result.updates.keys.map((key) {
      final source = result.sources[key]!;
      return HeadlessSourceUpdate(
        key: key,
        name: source.name,
        version: source.version,
        url: source.url,
        update: () => result.update(key),
      );
    }).toList(),
  );
}
