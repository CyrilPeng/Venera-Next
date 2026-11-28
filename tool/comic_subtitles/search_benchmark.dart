import 'dart:convert';
import 'dart:io';

import 'package:venera_next/features/reader/subtitles/binding.dart';
import 'package:venera_next/features/reader/subtitles/document.dart';
import 'package:venera_next/features/reader/subtitles/reading.dart';

void main(List<String> arguments) {
  const box = (left: 1, top: 2, right: 60, bottom: 20);
  final pages = <SubtitleBinding>[];
  for (var number = 0; number < 100; number++) {
    final areas = [
      for (final language in ['ja', 'zh'])
        for (var row = 0; row < 100; row++)
          SubtitleArea(
            'line-$number-$row',
            language,
            language == 'ja' ? '第$number 話 $row 山の下' : '第$number 话 $row 山脚下',
            box,
          ),
    ];
    final file = (
      path: 'page-$number',
      digest: 'sample-$number',
      number: number + 1,
    );
    pages.add(
      SubtitleBinding(
        SubtitlePage(
          'id-$number',
          file.path,
          file.digest,
          'ja',
          areas,
          200,
          300,
        ),
        [file],
        file,
      ),
    );
  }
  final buildTimes = <int>[];
  final queries = {'山': 10000, '脚下': 10000, '第52 话 42': 1, '日出': 0};
  final timings = {for (final query in queries.keys) query: <int>[]};
  for (var round = 0; round < 4; round++) {
    final build = Stopwatch()..start();
    final index = ChapterSubtitleIndex('chapter', pages);
    if (round > 0) buildTimes.add(build.elapsedMicroseconds);
    for (var repeat = 0; repeat < 10; repeat++) {
      for (final query in queries.entries) {
        final timer = Stopwatch()..start();
        final hits = index.search(query.key, 'zh').length;
        final elapsed = timer.elapsedMicroseconds;
        if (hits != query.value) {
          throw StateError('Incorrect hit count for ${query.key}');
        }
        if (round > 0) timings[query.key]!.add(elapsed);
      }
    }
  }
  final report = {
    'platform': Platform.operatingSystemVersion,
    'dart': Platform.version,
    'pages': pages.length,
    'dialogues': 10000,
    'languages': 2,
    'indexBuildUs': buildTimes,
    'queries': {
      for (final entry in timings.entries)
        entry.key: {
          'hits': queries[entry.key],
          'samples': entry.value.length,
          'p95Us': (entry.value..sort())[(entry.value.length * .95).ceil() - 1],
        },
    },
  };
  final output = const JsonEncoder.withIndent('  ').convert(report);
  if (arguments.isNotEmpty) File(arguments.single).writeAsStringSync(output);
  stdout.writeln(output);
}
