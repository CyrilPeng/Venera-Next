import 'package:path/path.dart' as path;
import 'package:venera_next/features/comic_storage/comic_storage.dart';
import 'package:venera_next/features/local_comics/import_export/cbz.dart';
import 'package:venera_next/features/local_comics/import_export/document_import.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:xml/xml.dart';

class EpubImportPage {
  const EpubImportPage({required this.file, required this.extension});

  final File file;
  final String extension;
}

class EpubImportChapter {
  const EpubImportChapter({required this.title, required this.pages});

  final String title;
  final List<EpubImportPage> pages;
}

class EpubImportData {
  const EpubImportData({
    required this.title,
    required this.author,
    required this.cover,
    required this.chapters,
    required this.preserveChapters,
  });

  final String title;
  final String author;
  final EpubImportPage cover;
  final List<EpubImportChapter> chapters;
  final bool preserveChapters;

  int get pageCount =>
      chapters.fold(0, (sum, chapter) => sum + chapter.pages.length);
}

abstract final class EpubComicImporter {
  static Future<LocalComic> import(
    File file, {
    DocumentImportProgress? onProgress,
  }) async {
    final cache = Directory(
      FilePath.join(
        App.cachePath,
        'epub_import_${DateTime.now().microsecondsSinceEpoch}',
      ),
    )..createSync(recursive: true);
    DocumentImportSession? session;
    try {
      await CBZ.extractArchive(file, cache);
      final data = inspectExtracted(
        cache,
        fallbackTitle: file.basenameWithoutExt,
      );
      session = DocumentImportSession.start(data.title);
      final coverName = await session.copyCover(
        data.cover.file,
        extension: data.cover.extension,
      );

      final chapterMap = <String, String>{};
      var importedPages = 0;
      var flatPageIndex = 0;
      for (
        var chapterIndex = 0;
        chapterIndex < data.chapters.length;
        chapterIndex++
      ) {
        final chapter = data.chapters[chapterIndex];
        final chapterId = data.preserveChapters
            ? chapterIndex.toString()
            : null;
        if (chapterId != null) {
          chapterMap[chapterId] = chapter.title;
        }
        for (var pageIndex = 0; pageIndex < chapter.pages.length; pageIndex++) {
          final page = chapter.pages[pageIndex];
          if (chapterId == null) flatPageIndex++;
          await session.copyPage(
            page.file,
            pageIndex: chapterId == null ? flatPageIndex : pageIndex + 1,
            extension: page.extension,
            chapterId: chapterId,
          );
          importedPages++;
          onProgress?.call(importedPages, data.pageCount);
        }
      }

      return session.finish(
        author: data.author,
        tags: const [],
        cover: coverName,
        chapters: chapterMap,
      );
    } catch (_) {
      await session?.abort();
      rethrow;
    } finally {
      await cache.deleteIgnoreError(recursive: true);
    }
  }

  static EpubImportData inspectExtracted(
    Directory root, {
    required String fallbackTitle,
  }) {
    final container = File(
      FilePath.join(root.path, 'META-INF', 'container.xml'),
    );
    if (!container.existsSync()) {
      throw const FormatException('EPUB container.xml is missing');
    }
    final containerXml = _parseXml(container);
    final rootFile = _elements(containerXml, 'rootfile')
        .map((element) => element.getAttribute('full-path')?.trim())
        .whereType<String>()
        .where((value) => value.isNotEmpty)
        .firstOrNull;
    if (rootFile == null) {
      throw const FormatException('EPUB package document is missing');
    }

    final opfRelativePath = _normalizeReference('', rootFile);
    final opfFile = _fileWithinRoot(root, opfRelativePath);
    if (!opfFile.existsSync()) {
      throw const FormatException('EPUB package document does not exist');
    }
    final opf = _parseXml(opfFile);
    final title = _firstText(opf, 'title')?.trim();
    final authors = _elements(opf, 'creator')
        .map((element) => element.innerText.trim())
        .where((value) => value.isNotEmpty)
        .toList();

    final manifest = <String, _ManifestItem>{};
    for (final element in _elements(opf, 'item')) {
      final id = element.getAttribute('id')?.trim();
      final href = element.getAttribute('href')?.trim();
      final mediaType = element.getAttribute('media-type')?.trim() ?? '';
      if (id == null || id.isEmpty || href == null || href.isEmpty) continue;
      final relativePath = _normalizeReference(opfRelativePath, href);
      manifest[id] = _ManifestItem(
        id: id,
        relativePath: relativePath,
        mediaType: mediaType.toLowerCase(),
        properties: (element.getAttribute('properties') ?? '')
            .split(RegExp(r'\s+'))
            .where((value) => value.isNotEmpty)
            .toSet(),
      );
    }

    final mediaTypesByPath = {
      for (final item in manifest.values) item.relativePath: item.mediaType,
    };
    final spine = _elements(opf, 'spine').firstOrNull;
    if (spine == null) {
      throw const FormatException('EPUB spine is missing');
    }
    final spineItems = <_ManifestItem>[];
    for (final itemRef in spine.childElements.where(
      (element) => element.name.local == 'itemref',
    )) {
      if (itemRef.getAttribute('linear')?.toLowerCase() == 'no') continue;
      final idRef = itemRef.getAttribute('idref');
      final item = idRef == null ? null : manifest[idRef];
      if (item == null) {
        throw const FormatException('EPUB spine references a missing item');
      }
      spineItems.add(item);
    }

    final navigationLabels = _readNavigationLabels(
      root,
      manifest,
      spine.getAttribute('toc'),
    );
    final sections = <_EpubSection>[];
    for (final item in spineItems) {
      final pages = _readItemPages(root, item, mediaTypesByPath);
      if (pages.isEmpty) continue;
      sections.add(
        _EpubSection(
          relativePath: item.relativePath,
          pages: pages,
          label: navigationLabels[item.relativePath],
        ),
      );
    }
    if (sections.isEmpty) {
      throw const FormatException('EPUB contains no supported image pages');
    }

    final labeledSections = sections
        .where((section) => section.label != null)
        .length;
    final preserveChapters = labeledSections >= 2;
    final chapters = <EpubImportChapter>[];
    if (preserveChapters) {
      EpubImportChapter? current;
      for (final section in sections) {
        if (section.label != null || current == null) {
          current = EpubImportChapter(
            title: section.label ?? fallbackTitle,
            pages: <EpubImportPage>[],
          );
          chapters.add(current);
        }
        current.pages.addAll(section.pages);
      }
    } else {
      chapters.add(
        EpubImportChapter(
          title: title?.isNotEmpty == true ? title! : fallbackTitle,
          pages: sections.expand((section) => section.pages).toList(),
        ),
      );
    }

    final cover =
        _findCover(root, opf, manifest, mediaTypesByPath) ??
        sections.first.pages.first;
    return EpubImportData(
      title: title?.isNotEmpty == true ? title! : fallbackTitle,
      author: authors.join(', '),
      cover: cover,
      chapters: chapters,
      preserveChapters: preserveChapters,
    );
  }
}

class _ManifestItem {
  const _ManifestItem({
    required this.id,
    required this.relativePath,
    required this.mediaType,
    required this.properties,
  });

  final String id;
  final String relativePath;
  final String mediaType;
  final Set<String> properties;
}

class _EpubSection {
  const _EpubSection({
    required this.relativePath,
    required this.pages,
    required this.label,
  });

  final String relativePath;
  final List<EpubImportPage> pages;
  final String? label;
}

XmlDocument _parseXml(File file) {
  try {
    return XmlDocument.parse(file.readAsStringSync());
  } on XmlParserException catch (error) {
    throw FormatException('Invalid EPUB XML in ${file.name}: $error');
  }
}

Iterable<XmlElement> _elements(XmlNode node, String localName) {
  return node.descendants.whereType<XmlElement>().where(
    (element) => element.name.local == localName,
  );
}

String? _firstText(XmlNode node, String localName) {
  return _elements(node, localName).firstOrNull?.innerText;
}

List<EpubImportPage> _readItemPages(
  Directory root,
  _ManifestItem item,
  Map<String, String> mediaTypesByPath,
) {
  final file = _fileWithinRoot(root, item.relativePath);
  if (!file.existsSync()) {
    throw FormatException('EPUB spine file is missing: ${item.relativePath}');
  }
  final directImage = _asImagePage(file, item.mediaType);
  if (directImage != null) return [directImage];

  final isMarkup =
      item.mediaType == 'application/xhtml+xml' ||
      item.mediaType == 'text/html' ||
      item.mediaType == 'image/svg+xml';
  if (!isMarkup) {
    throw FormatException('Unsupported EPUB spine item: ${item.mediaType}');
  }
  final xml = _parseXml(file);
  final references = <String>[];
  for (final element in xml.descendants.whereType<XmlElement>()) {
    final localName = element.name.local.toLowerCase();
    if (localName == 'img') {
      final source = element.getAttribute('src')?.trim();
      if (source != null && source.isNotEmpty) references.add(source);
    } else if (localName == 'image') {
      final source = element.attributes
          .where((attribute) => attribute.name.local == 'href')
          .map((attribute) => attribute.value.trim())
          .where((value) => value.isNotEmpty)
          .firstOrNull;
      if (source != null) references.add(source);
    }
  }
  if (references.isEmpty) {
    if (item.mediaType == 'image/svg+xml') {
      throw const FormatException('Direct SVG pages are not supported');
    }
    final body = _elements(xml, 'body').firstOrNull;
    if ((body?.innerText ?? '').trim().isNotEmpty) {
      throw const FormatException('Text-based EPUB files are not supported');
    }
    return const [];
  }

  return references.map((reference) {
    final relativePath = _normalizeReference(item.relativePath, reference);
    final imageFile = _fileWithinRoot(root, relativePath);
    if (!imageFile.existsSync()) {
      throw FormatException('EPUB image is missing: $relativePath');
    }
    final page = _asImagePage(imageFile, mediaTypesByPath[relativePath] ?? '');
    if (page == null) {
      throw FormatException('Unsupported EPUB image: $relativePath');
    }
    return page;
  }).toList();
}

EpubImportPage? _asImagePage(File file, String mediaType) {
  final fileExtension = comicFileExtension(file.name);
  if (comicImageExtensions.contains(fileExtension)) {
    return EpubImportPage(file: file, extension: fileExtension);
  }
  final extension = switch (mediaType.toLowerCase()) {
    'image/jpeg' => 'jpg',
    'image/png' => 'png',
    'image/webp' => 'webp',
    'image/gif' => 'gif',
    'image/avif' => 'avif',
    _ => null,
  };
  return extension == null
      ? null
      : EpubImportPage(file: file, extension: extension);
}

Map<String, String> _readNavigationLabels(
  Directory root,
  Map<String, _ManifestItem> manifest,
  String? tocId,
) {
  final labels = <String, String>{};
  final navItem = manifest.values
      .where((item) => item.properties.contains('nav'))
      .firstOrNull;
  if (navItem != null) {
    final navFile = _fileWithinRoot(root, navItem.relativePath);
    if (navFile.existsSync()) {
      final nav = _parseXml(navFile);
      for (final anchor in _elements(nav, 'a')) {
        final href = anchor.getAttribute('href')?.trim();
        final label = anchor.innerText.trim();
        if (href == null || href.isEmpty || label.isEmpty) continue;
        try {
          labels.putIfAbsent(
            _normalizeReference(navItem.relativePath, href),
            () => label,
          );
        } on FormatException {
          continue;
        }
      }
    }
  }

  final ncxItem = tocId == null
      ? manifest.values
            .where((item) => item.mediaType == 'application/x-dtbncx+xml')
            .firstOrNull
      : manifest[tocId];
  if (ncxItem != null) {
    final ncxFile = _fileWithinRoot(root, ncxItem.relativePath);
    if (ncxFile.existsSync()) {
      final ncx = _parseXml(ncxFile);
      for (final navPoint in _elements(ncx, 'navPoint')) {
        final content = navPoint.childElements
            .where((element) => element.name.local == 'content')
            .firstOrNull;
        final navLabel = navPoint.childElements
            .where((element) => element.name.local == 'navLabel')
            .firstOrNull;
        final source = content?.getAttribute('src')?.trim();
        final label = navLabel == null
            ? null
            : _firstText(navLabel, 'text')?.trim();
        if (source == null ||
            source.isEmpty ||
            label == null ||
            label.isEmpty) {
          continue;
        }
        labels.putIfAbsent(
          _normalizeReference(ncxItem.relativePath, source),
          () => label,
        );
      }
    }
  }
  return labels;
}

EpubImportPage? _findCover(
  Directory root,
  XmlDocument opf,
  Map<String, _ManifestItem> manifest,
  Map<String, String> mediaTypesByPath,
) {
  String? coverId;
  for (final meta in _elements(opf, 'meta')) {
    if (meta.getAttribute('name')?.toLowerCase() == 'cover') {
      coverId = meta.getAttribute('content')?.trim();
      if (coverId?.isNotEmpty == true) break;
    }
  }
  final coverItem = coverId == null
      ? manifest.values
            .where((item) => item.properties.contains('cover-image'))
            .firstOrNull
      : manifest[coverId];
  if (coverItem == null) return null;
  try {
    final pages = _readItemPages(root, coverItem, mediaTypesByPath);
    return pages.firstOrNull;
  } on FormatException {
    return null;
  }
}

String _normalizeReference(String baseRelativePath, String reference) {
  final uri = Uri.tryParse(reference.trim());
  if (uri == null || uri.hasScheme || uri.hasAuthority) {
    throw FormatException('EPUB contains an external reference: $reference');
  }
  final decodedPath = Uri.decodeFull(uri.path).replaceAll('\\', '/');
  if (decodedPath.isEmpty || path.posix.isAbsolute(decodedPath)) {
    throw FormatException('EPUB contains an invalid path: $reference');
  }
  final normalized = path.posix.normalize(
    path.posix.join(path.posix.dirname(baseRelativePath), decodedPath),
  );
  if (normalized == '..' || normalized.startsWith('../')) {
    throw FormatException('EPUB path escapes the archive: $reference');
  }
  return normalized;
}

File _fileWithinRoot(Directory root, String relativePath) {
  final rootPath = path.absolute(root.path);
  final filePath = path.absolute(
    path.joinAll([root.path, ...relativePath.split('/')]),
  );
  if (filePath != rootPath && !path.isWithin(rootPath, filePath)) {
    throw FormatException('EPUB path escapes the archive: $relativePath');
  }
  return File(filePath);
}
