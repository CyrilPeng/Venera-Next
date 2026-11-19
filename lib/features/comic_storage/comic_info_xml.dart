import 'package:xml/xml.dart';

import 'archive_metadata.dart';

/// Reader for the standard [ComicInfo.xml](https://github.com/anansi-project/comicinfo)
/// companion file found inside CBZ/CB7 archives.
///
/// The exporter in `cbz.dart` writes metadata here and embeds chapter ranges
/// in `<Notes>` using the Venera convention. Archives without JSON metadata
/// can restore that convention when the ranges cover their actual flat pages.
class ComicInfoXml {
  ComicInfoXml._();

  /// Returns the `<Notes>` text, or null when absent.
  static String? readNotes(String xml) {
    final document = _parse(xml);
    if (document == null) return null;
    final root = document.rootElement;
    for (final child in root.childElements) {
      if (child.name.local == 'Notes') {
        return child.innerText.trim();
      }
    }
    return null;
  }

  /// Reads `<Title>`, `<Writer>`, `<Genre>` / `<Tags>` into a [ComicMetaData].
  static ComicMetaData? readMetadata(String xml) {
    final document = _parse(xml);
    if (document == null) return null;
    final root = document.rootElement;
    final title = _childText(root, 'Title')?.trim();
    if (title == null || title.isEmpty) return null;
    final writer = _childText(root, 'Writer')?.trim() ?? '';
    final tags = <String>[
      ...?_listFromComma(_childText(root, 'Genre')),
      ...?_listFromComma(_childText(root, 'Tags')),
    ];
    return ComicMetaData(
      title: title,
      author: writer,
      tags: tags,
      chapters: _readChaptersFromNotes(root),
    );
  }

  static List<ComicChapter>? _readChaptersFromNotes(XmlElement root) {
    final notes = _childText(root, 'Notes')?.trim();
    if (notes == null || notes.isEmpty) return null;
    return parseChaptersFromNotes(notes);
  }

  static XmlDocument? _parse(String xml) {
    try {
      return XmlDocument.parse(xml);
    } catch (_) {
      return null;
    }
  }

  static String? _childText(XmlElement parent, String localName) {
    for (final child in parent.childElements) {
      if (child.name.local == localName) {
        return child.innerText;
      }
    }
    return null;
  }

  static List<String>? _listFromComma(String? value) {
    if (value == null) return null;
    final list = value
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
    return list.isEmpty ? null : list;
  }
}

/// Parses the `Chapters: title: start-end; title: start-end` convention the
/// Venera exporter writes into `ComicInfo.xml` `<Notes>`.
///
/// Returns null when the notes do not carry a usable chapter list, so callers
/// can fall back to the flat single-volume behavior.
List<ComicChapter>? parseChaptersFromNotes(String notes) {
  const prefix = 'Chapters:';
  final trimmed = notes.trim();
  if (!trimmed.startsWith(prefix)) return null;

  final chapters = <ComicChapter>[];
  var previousEnd = 0;
  final tokens = trimmed.substring(prefix.length).split(';');
  for (final token in tokens) {
    final chapter = _parseChapterToken(token.trim());
    if (chapter == null) return null;
    if (chapter.start <= previousEnd) return null;
    previousEnd = chapter.end;
    chapters.add(chapter);
  }
  return chapters.isEmpty ? null : chapters;
}

ComicChapter? _parseChapterToken(String token) {
  if (token.isEmpty) return null;
  final separatorIndex = token.lastIndexOf(':');
  if (separatorIndex <= 0) return null;
  final title = token.substring(0, separatorIndex).trim();
  final range = token.substring(separatorIndex + 1).trim();
  if (title.isEmpty) return null;
  final rangeMatch = RegExp(r'^(\d+)\s*-\s*(\d+)$').firstMatch(range);
  if (rangeMatch == null) return null;
  final start = int.tryParse(rangeMatch.group(1)!);
  final end = int.tryParse(rangeMatch.group(2)!);
  if (start == null || end == null || end < start) return null;
  return ComicChapter(title: title, start: start, end: end);
}
