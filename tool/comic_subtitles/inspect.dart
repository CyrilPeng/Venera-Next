import 'dart:convert';
import 'dart:io';

import 'package:venera_next/features/reader/subtitles/document.dart';

void main(List<String> arguments) {
  if (arguments.length != 2) {
    stderr.writeln('Usage: dart run inspect.dart book.acbf book.pages.json');
    exitCode = 64;
    return;
  }
  final document = SubtitleDocument.parse(
    File(arguments.first).readAsBytesSync(),
    manifest: File(arguments.last).readAsBytesSync(),
  );
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
