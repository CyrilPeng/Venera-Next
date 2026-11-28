import 'package:unorm_dart/unorm_dart.dart' as unicode;

import 'binding.dart';
import 'document.dart';

class SubtitleHit {
  const SubtitleHit(this.chapter, this.file, this.page, this.area);
  final String chapter;
  final SubtitleFile file;
  final SubtitlePage page;
  final SubtitleArea area;
}

String subtitleSearchText(String text) =>
    unicode.nfkc(text).toLowerCase().trim();

class ChapterSubtitleIndex {
  ChapterSubtitleIndex(this.chapter, List<SubtitleBinding> bindings) {
    for (final binding in bindings) {
      final file = binding.selected;
      if (file == null) continue;
      byFile[file.path] = binding.page;
      final grouped = <(String, String), (SubtitleArea, StringBuffer)>{};
      for (final area in binding.page.areas) {
        languages.add(area.language);
        final group = grouped.putIfAbsent((
          area.dialogue,
          area.language,
        ), () => (area, StringBuffer()));
        group.$2.write(area.text);
      }
      for (final (area, content) in grouped.values) {
        final joined = content.toString();
        final hitArea = joined == area.text
            ? area
            : SubtitleArea(area.dialogue, area.language, joined, area.bounds);
        _entries.add((
          SubtitleHit(chapter, file, binding.page, hitArea),
          subtitleSearchText(joined),
        ));
      }
    }
  }
  final String chapter;
  final byFile = <String, SubtitlePage>{};
  final languages = <String>{};
  final _entries = <(SubtitleHit, String)>[];

  Iterable<SubtitleHit> search(String query, String? language) sync* {
    final needle = subtitleSearchText(query);
    if (needle.isEmpty) return;
    final seen = <String>{};
    for (final (hit, text) in _entries) {
      final visible = subtitleLanguage(hit.page, language);
      if (hit.area.language != hit.page.sourceLanguage &&
          hit.area.language != visible) {
        continue;
      }
      if (text.contains(needle) && seen.add(hit.area.dialogue)) yield hit;
    }
  }
}

String? subtitleLanguage(SubtitlePage page, String? requested) {
  if (requested != null &&
      page.areas.any((area) => area.language == requested)) {
    return requested;
  }
  return page.areas
          .where((area) => area.language != page.sourceLanguage)
          .firstOrNull
          ?.language ??
      page.sourceLanguage;
}
