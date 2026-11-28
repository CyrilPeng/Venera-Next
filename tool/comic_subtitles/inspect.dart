import 'dart:convert';
import 'dart:io';

import 'package:venera_next/features/reader/subtitles/document.dart';

void main(List<String> arguments) {
  if (arguments.length < 2) {
    stderr.writeln(
      'Usage: inspect.dart book.acbf book.pages.json [new-directory image-name ...]',
    );
    exitCode = 64;
    return;
  }
  final acbf = File(arguments[0]).readAsBytesSync();
  final manifest = File(arguments[1]).readAsBytesSync();
  final document = SubtitleDocument.parse(acbf, manifest: manifest);
  if (arguments.length > 2) {
    final directory = Directory(arguments[2]);
    if (directory.existsSync()) throw StateError('Choose a new directory');
    final files = rewriteSubtitleReferences(
      acbf,
      manifest,
      arguments.sublist(3),
    );
    directory.createSync();
    File('${directory.path}/book.acbf').writeAsBytesSync(files.acbf);
    File('${directory.path}/book.pages.json').writeAsBytesSync(files.manifest);
  }
  stdout.writeln(
    jsonEncode([
      for (final page in document.pages)
        {
          'page': page.id,
          'dialogues': [
            for (final area in page.areas)
              {
                'id': area.dialogue,
                'language': area.language,
                'text': area.text,
              },
          ],
        },
    ]),
  );
}
