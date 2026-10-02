import 'package:venera_next/foundation/res.dart';

enum HeadlessCommand { webdav, updateScript, updateSubscribe }

class HeadlessRequest {
  const HeadlessRequest(this.command, {this.subcommand, this.comic});
  final HeadlessCommand command;
  final String? subcommand;
  final ({String id, String sourceKey})? comic;
}

/// Validate before initializing plugins, databases or application data.
Res<HeadlessRequest> parseHeadlessArguments(List<String> args) {
  final marker = args.indexOf('--headless');
  final values = marker < 0
      ? <String>[]
      : args
            .skip(marker + 1)
            .where((value) => value != '--ignore-disheadless-log')
            .toList();
  if (values.isEmpty) {
    return const Res.error('No command provided for headless mode.');
  }
  switch (values.first) {
    case 'webdav':
      if (values.length != 2 || !['up', 'down'].contains(values[1])) {
        return const Res.error('Invalid webdav command. Use "up" or "down".');
      }
      return Res(
        HeadlessRequest(HeadlessCommand.webdav, subcommand: values[1]),
      );
    case 'updatescript':
      if (values.length != 2 || values[1] != 'all') {
        return const Res.error('Invalid updatescript command. Use "all".');
      }
      return const Res(
        HeadlessRequest(HeadlessCommand.updateScript, subcommand: 'all'),
      );
    case 'updatesubscribe':
      if (values.length == 1) {
        return const Res(HeadlessRequest(HeadlessCommand.updateSubscribe));
      }
      if (values.length != 4 ||
          values[1] != '--update-comic-by-id-type' ||
          values[2].isEmpty ||
          values[3].isEmpty ||
          values[2].startsWith('--') ||
          values[3].startsWith('--')) {
        return const Res.error(
          'Invalid updatesubscribe options. Use --update-comic-by-id-type <id> <type>.',
        );
      }
      return Res(
        HeadlessRequest(
          HeadlessCommand.updateSubscribe,
          comic: (id: values[2], sourceKey: values[3]),
        ),
      );
    default:
      return Res.error('Unknown command: ${values.first}');
  }
}
