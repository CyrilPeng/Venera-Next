import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/local_comics/import_export/cbz.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/features/reader/comic_image.dart';
import 'package:venera_next/features/reader/continuous_view.dart';
import 'package:venera_next/features/reader/reader_page.dart';
import 'package:venera_next/features/reader/subtitles/archive.dart';
import 'package:venera_next/features/reader/subtitles/binding.dart';
import 'package:venera_next/features/reader/subtitles/overlay.dart';
import 'package:venera_next/features/reader/subtitles/store.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/main.dart' as application;
import 'package:venera_next/routing/app_navigation.dart';

Iterable<Element> elements(Element? root) sync* {
  if (root == null) return;
  final pending = [root];
  while (pending.isNotEmpty) {
    final node = pending.removeLast();
    yield node;
    node.visitChildren(pending.add);
  }
}

Future<void> until(bool Function() ready, String stage) async {
  final timer = Stopwatch()..start();
  while (!ready()) {
    if (timer.elapsed > const Duration(seconds: 30)) {
      throw StateError('Timed out at $stage');
    }
    await Future<void>.delayed(const Duration(milliseconds: 16));
  }
}

bool hasPaintedPage(Element? root) => elements(root).any(
  (node) =>
      node.widget is RawImage &&
      (node.widget as RawImage).image != null &&
      node.findAncestorWidgetOfExactType<ComicImage>() != null,
);

Future<Map<String, Object>> measure(
  LocalComic comic,
  bool enabled,
  int round,
) async {
  appdata.settings['externalSubtitles'] = enabled;
  final cache = PaintingBinding.instance.imageCache;
  cache.clear();
  cache.clearLiveImages();
  ComicImage.clear();
  final key = GlobalKey<ReaderState>();
  final navigator = appNavigation.rootNavigatorKey.currentState!;
  final route = PageRouteBuilder<void>(
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
    pageBuilder: (context, animation, secondary) => Reader(
      key: key,
      type: comic.comicType,
      cid: comic.id,
      name: comic.title,
      chapters: comic.chapters,
      history: History.fromModel(model: comic, ep: 1, page: 1),
      initialPage: 1,
      initialChapter: 1,
      author: '',
      tags: const [],
      onClosed: () {},
    ),
  );
  final frames = <FrameTiming>[];
  void record(List<FrameTiming> values) => frames.addAll(values);
  SchedulerBinding.instance.addTimingsCallback(record);
  var peak = ProcessInfo.currentRss;
  final sampler = Timer.periodic(
    const Duration(milliseconds: 32),
    (_) => peak = math.max(peak, ProcessInfo.currentRss),
  );
  final clock = Stopwatch()..start();
  unawaited(navigator.push(route));
  try {
    await until(
      () => hasPaintedPage(key.currentContext as Element?),
      'first original image',
    );
    final first = clock.elapsedMicroseconds;
    if (enabled) {
      await until(
        () => elements(key.currentContext as Element?).any(
          (element) =>
              element.widget is Text && (element.widget as Text).data == '山脚下',
        ),
        'first translated dialogue',
      );
    }
    await until(
      () => key.currentState?.imageViewController is ContinuousModeState,
      'continuous reader',
    );
    final viewport =
        key.currentState!.imageViewController as ContinuousModeState;
    final scroll = viewport.scrollController;
    await until(
      () => scroll.hasClients && scroll.position.maxScrollExtent > 32,
      'scrollable pages',
    );
    final start = developer.Timeline.now;
    final distance = math.min(
      scroll.position.maxScrollExtent,
      scroll.position.viewportDimension * 1.5,
    );
    await scroll.animateTo(
      distance,
      duration: const Duration(milliseconds: 1100),
      curve: Curves.linear,
    );
    await scroll.animateTo(
      0,
      duration: const Duration(milliseconds: 1100),
      curve: Curves.linear,
    );
    final end = developer.Timeline.now;
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    final samples =
        frames
            .where((frame) {
              final stamp = frame.timestampInMicroseconds(
                FramePhase.vsyncStart,
              );
              return stamp >= start && stamp <= end;
            })
            .map((frame) => frame.totalSpan.inMicroseconds)
            .toList()
          ..sort();
    if (samples.isEmpty) {
      throw StateError('No engine frame timings during scrolling');
    }
    if (enabled) {
      final scope = elements(
        key.currentContext as Element?,
      ).map((node) => node.widget).whereType<SubtitleScope>().first;
      final index = scope.notifier!.indexes['0']!;
      final hit = index.search('日出', 'zh').single;
      key.currentState!.toPage(
        key.currentState!.pageLayout.pageForImage(hit.file.number),
        animated: false,
      );
      scope.notifier!.highlight(hit);
      await until(
        () => elements(key.currentContext as Element?).any((node) {
          if (node.widget is! Text || (node.widget as Text).data != '日出') {
            return false;
          }
          final box = node.findRenderObject();
          if (box is! RenderBox || !box.attached || !box.hasSize) return false;
          final viewportBox =
              key.currentContext!.findRenderObject()! as RenderBox;
          final center = box.localToGlobal(
            box.size.center(Offset.zero),
            ancestor: viewportBox,
          );
          return (Offset.zero & viewportBox.size).contains(center);
        }),
        'sunrise bubble inside viewport',
      );
    }
    return {
      'round': round,
      'enabled': enabled,
      'firstImageUs': first,
      'scrollFrames': samples.length,
      'scrollP95Us': samples[(samples.length * .95).ceil() - 1],
      'peakRssBytes': peak,
    };
  } finally {
    sampler.cancel();
    SchedulerBinding.instance.removeTimingsCallback(record);
    if (route.isActive) navigator.removeRoute(route);
    await until(() => key.currentState == null, 'reader disposal');
  }
}

Future<void> main() async {
  const seed = String.fromEnvironment('SUBTITLE_TRIAL_CBZ');
  const revision = String.fromEnvironment('SUBTITLE_TRIAL_REVISION');
  if (seed.isEmpty || revision.isEmpty) {
    throw StateError('Use the subtitle trial workflow and its sample');
  }
  final report = <String, Object>{
    'revision': revision,
    'platform': Platform.operatingSystemVersion,
  };
  try {
    application.main([]);
    await until(
      () => appNavigation.rootNavigatorKey.currentState != null,
      'application startup',
    );
    final file = File('${App.cachePath}/subtitle-trial.cbz');
    final data = base64Decode(seed);
    await file.writeAsBytes(data);
    report['sampleSha256'] = sha256.convert(data).toString();
    final comic = await CBZ.import(
      file,
      registerComic: (comic) => LocalManager().add(comic, comic.id),
    );
    final urls = await LocalManager().getImages(comic.id, comic.comicType, 1);
    final files = await fingerprintSubtitleImages(urls);
    final subtitle = (await readArchivedSubtitles(
      File(files.first.path).parent,
    ))!;
    final bound = bindSubtitlePages(subtitle.parse(), files, {});
    if (bound.length != 3 || bound.any((item) => item.selected == null)) {
      throw StateError('Page binding differs');
    }
    SubtitleStore(
      '${App.dataPath}/comic-subtitles.db',
    ).replace(comic.id, '0', null, subtitle);
    appdata.settings['readerMode'] = 'continuousTopToBottom';
    appdata.settings['pagedReaderMode'] = 'continuousTopToBottom';
    appdata.settings['longStripReaderMode'] = 'continuousTopToBottom';
    appdata.settings['autoReaderMode'] = false;
    final rounds = <Map<String, Object>>[];
    report['rounds'] = rounds;
    for (var round = 1; round <= 3; round++) {
      for (final enabled in (round.isEven ? [true, false] : [false, true])) {
        rounds.add(await measure(comic, enabled, round));
      }
    }
    final after = await fingerprintSubtitleImages(urls);
    if (after.map((file) => file.digest).join() !=
        files.map((file) => file.digest).join()) {
      throw StateError('Original page bytes changed');
    }
    report['pageSha256'] = after.map((file) => file.digest).toList();
    report['passed'] = true;
  } catch (error, stack) {
    report['error'] = '$error';
    report['trace'] = stack.toString().split('\n').take(4).join('\n');
  }
  final output = jsonEncode(report);
  final destination = Platform.environment['SUBTITLE_TRIAL_OUTPUT'];
  if (destination != null) {
    File(destination).writeAsStringSync(output, flush: true);
  }
  debugPrintSynchronously('SUBTITLE_TRIAL_RESULT $output');
  exit(report['passed'] == true ? 0 : 1);
}
