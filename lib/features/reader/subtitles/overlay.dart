import 'dart:async';

import 'package:flutter/material.dart';

import '../image_position.dart';
import 'document.dart';
import 'reading.dart';

class SubtitleDisplay extends ChangeNotifier {
  SubtitleDisplay(this.load);
  final Future<ChapterSubtitleIndex> Function(String) load;
  final indexes = <String, ChapterSubtitleIndex>{};
  final _loads = <String, Future<void>>{};
  bool visible = true;
  String? language;
  SubtitleHit? focus;
  bool _disposed = false;
  Timer? _timer;
  int _generation = 0;
  int _navigation = 0;
  int startNavigation() => ++_navigation;
  bool acceptsNavigation(int token) => !_disposed && _navigation == token;
  String? loadError;

  Future<void> ensure(String chapter) => _loads.putIfAbsent(chapter, () async {
    final generation = _generation;
    try {
      final index = await load(chapter);
      if (_disposed || generation != _generation) return;
      indexes[chapter] = index;
    } catch (error) {
      if (_disposed || generation != _generation) return;
      loadError = error.toString();
    }
    notifyListeners();
  });

  void refresh() {
    _generation++;
    _navigation++;
    _loads.clear();
    indexes.clear();
    loadError = null;
    highlight(null);
  }

  void configure(bool show, String? selected) {
    visible = show;
    language = selected;
    notifyListeners();
  }

  void highlight(SubtitleHit? hit) {
    _timer?.cancel();
    focus = hit;
    notifyListeners();
  }

  void reveal(BuildContext context, SubtitleHit hit) {
    if (!context.mounted ||
        !identical(focus, hit) ||
        _timer?.isActive == true) {
      return;
    }
    unawaited(Scrollable.ensureVisible(context, alignment: 0.5));
    _timer = Timer(const Duration(seconds: 3), () => highlight(null));
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

class SubtitleScope extends InheritedNotifier<SubtitleDisplay> {
  const SubtitleScope({
    super.key,
    required super.notifier,
    required super.child,
  });
  static SubtitleDisplay? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SubtitleScope>()?.notifier;
}

List<Rect> projectSubtitleArea({
  required SubtitleBounds area,
  required Size original,
  required Size decoded,
  required Rect crop,
  required Rect destination,
  required bool split,
  required bool invert,
}) {
  if (original.isEmpty ||
      decoded.isEmpty ||
      crop.isEmpty ||
      destination.isEmpty) {
    return [];
  }
  final rect = Rect.fromLTRB(
    area.left * decoded.width / original.width,
    area.top * decoded.height / original.height,
    area.right * decoded.width / original.width,
    area.bottom * decoded.height / original.height,
  );
  Rect? project(Rect source, Rect target) {
    final visible = rect.intersect(source);
    if (visible.isEmpty) return null;
    return Rect.fromLTRB(
      target.left + (visible.left - source.left) * target.width / source.width,
      target.top + (visible.top - source.top) * target.height / source.height,
      target.left + (visible.right - source.left) * target.width / source.width,
      target.top +
          (visible.bottom - source.top) * target.height / source.height,
    );
  }

  if (!split) return [?project(crop, destination)];
  return [
    for (final slice in splitWideImageSlices(invert: invert))
      ?project(
        Rect.fromLTWH(
          crop.left + crop.width * slice.sourceLeft,
          crop.top,
          crop.width * slice.sourceWidth,
          crop.height,
        ),
        Rect.fromLTWH(
          destination.left,
          destination.top + destination.height * slice.displayTop,
          destination.width,
          destination.height * slice.displayHeight,
        ),
      ),
  ];
}

class PageSubtitleLayer extends StatelessWidget {
  const PageSubtitleLayer({
    super.key,
    required this.chapter,
    required this.imageKey,
    required this.original,
    required this.decoded,
    required this.crop,
    required this.fit,
    required this.alignment,
    required this.split,
    required this.invert,
    required this.scale,
  });
  final String chapter, imageKey;
  final Size original, decoded;
  final Rect crop;
  final BoxFit fit;
  final Alignment alignment;
  final bool split, invert;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final display = SubtitleScope.of(context);
    if (display == null || !imageKey.startsWith('file://')) {
      return const SizedBox.shrink();
    }
    unawaited(display.ensure(chapter));
    final page = display.indexes[chapter]?.byFile[imageKey.substring(7)];
    if (page == null || (!display.visible && display.focus == null)) {
      return const SizedBox.shrink();
    }
    final language = subtitleLanguage(page, display.language);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final sourceSize = split
            ? Size(crop.width / 2, crop.height * 2)
            : crop.size;
        final fitted = applyBoxFit(fit, sourceSize / scale, size);
        final dest = alignment.inscribe(fitted.destination, Offset.zero & size);
        final source = split
            ? crop
            : alignment.inscribe(fitted.source * scale, crop);
        final pieces = <Widget>[];
        final hit = display.focus;
        bool anchored = false;
        for (final area in page.areas) {
          final matching =
              hit != null &&
              hit.chapter == chapter &&
              hit.page.id == page.id &&
              hit.area.dialogue == area.dialogue;
          if (area.language != language &&
              !(matching &&
                  area.language == hit.area.language &&
                  !page.areas.any(
                    (item) =>
                        item.dialogue == area.dialogue &&
                        item.language == language,
                  ))) {
            continue;
          }
          if (!display.visible && !matching) continue;
          final rects = projectSubtitleArea(
            area: area.bounds,
            original: original,
            decoded: decoded,
            crop: source,
            destination: dest,
            split: split,
            invert: invert,
          );
          for (final rect in rects) {
            final anchor = matching && !anchored;
            anchored |= anchor;
            pieces.add(
              Positioned.fromRect(
                rect: rect,
                child: Builder(
                  builder: (context) {
                    if (anchor) {
                      WidgetsBinding.instance.addPostFrameCallback(
                        (_) => display.reveal(context, hit),
                      );
                    }
                    final marker =
                        rect.width < 22 || rect.height < 12 || rects.length > 1;
                    return Material(
                      color: display.visible
                          ? Colors.white
                          : Colors.transparent,
                      child: InkWell(
                        onTap: () => showDialog<void>(
                          context: context,
                          builder: (_) =>
                              AlertDialog(content: SelectableText(area.text)),
                        ),
                        child: Container(
                          decoration: matching
                              ? BoxDecoration(
                                  border: Border.all(
                                    color: Colors.orange,
                                    width: 2,
                                  ),
                                )
                              : null,
                          alignment: Alignment.center,
                          child: display.visible
                              ? FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: marker
                                      ? const Icon(
                                          Icons.chat_bubble_outline,
                                          size: 16,
                                          color: Colors.black,
                                        )
                                      : Text(
                                          area.text,
                                          style: const TextStyle(
                                            color: Colors.black,
                                          ),
                                        ),
                                )
                              : null,
                        ),
                      ),
                    );
                  },
                ),
              ),
            );
          }
        }
        return Stack(children: pieces);
      },
    );
  }
}
