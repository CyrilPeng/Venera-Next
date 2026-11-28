import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

const subtitleNamespace = 'http://www.acbf.info/xml/acbf/1.1';

class SubtitleLimits {
  const SubtitleLimits({
    this.bytes = 16 << 20,
    this.pages = 2048,
    this.areas = 50000,
    this.pixels = 64000000,
    this.textLength = 65536,
  });
  final int bytes, pages, areas, pixels, textLength;
}

void _require(bool condition, String message) {
  if (!condition) throw FormatException(message);
}

typedef SubtitleBounds = ({int left, int top, int right, int bottom});

class SubtitleArea {
  const SubtitleArea(this.dialogue, this.language, this.text, this.bounds);
  final String dialogue, language, text;
  final SubtitleBounds bounds;
}

class SubtitlePage {
  const SubtitlePage(
    this.id,
    this.image,
    this.digest,
    this.sourceLanguage,
    this.areas,
    this.width,
    this.height,
  );
  final String id, image;
  final String? digest, sourceLanguage;
  final int? width, height;
  final List<SubtitleArea> areas;
}

typedef _ImageIdentity = ({String digest, int width, int height});

class SubtitleDocument {
  const SubtitleDocument(this.pages);
  final List<SubtitlePage> pages;

  static SubtitleDocument parse(
    Uint8List bytes, {
    Uint8List? manifest,
    SubtitleLimits limits = const SubtitleLimits(),
  }) {
    _require(
      bytes.length + (manifest?.length ?? 0) <= limits.bytes,
      'Subtitle files exceed the size limit',
    );
    final source = utf8.decode(bytes);
    _require(!source.contains('<!DOCTYPE'), 'Unsupported XML declaration');
    var depth = 0;
    var elements = 0;
    for (final event in parseEvents(
      source,
      validateDocument: true,
      validateNesting: true,
    )) {
      if (event is XmlStartElementEvent) {
        _require(
          ++elements <= 300000 && depth < 48,
          'XML structure exceeds the limit',
        );
        if (!event.isSelfClosing) depth++;
      } else if (event is XmlEndElementEvent) {
        depth--;
      } else if (event is XmlDoctypeEvent || event is XmlProcessingEvent) {
        throw const FormatException('Unsupported XML declaration');
      }
    }
    final root = XmlDocument.parse(source).rootElement;
    _require(
      root.name.local == 'ACBF' && root.namespaceUri == subtitleNamespace,
      'Expected ACBF 1.1',
    );
    final embedded = <String, _ImageIdentity>{};
    for (final data in _children(root, 'data')) {
      for (final binary in _children(data, 'binary')) {
        final id = _identifier(binary.getAttribute('id'));
        _require(!embedded.containsKey(id), 'Duplicate resource ID');
        final content = base64.decode(
          binary.innerText.replaceAll(RegExp(r'\s'), ''),
        );
        _require(
          content.length >= 24 &&
              content[0] == 137 &&
              ascii.decode(content.sublist(1, 4), allowInvalid: true) ==
                  'PNG' &&
              ByteData.sublistView(content).getUint32(4) == 0x0d0a1a0a &&
              ByteData.sublistView(content).getUint32(8) == 13 &&
              ascii.decode(content.sublist(12, 16), allowInvalid: true) ==
                  'IHDR',
          'Embedded subtitle resources must be PNG images',
        );
        final header = ByteData.sublistView(content);
        final width = header.getUint32(16), height = header.getUint32(20);
        _checkSize(width, height, limits);
        embedded[id] = (
          digest: sha256.convert(content).toString(),
          width: width,
          height: height,
        );
      }
    }
    final bodies = _children(root, 'body');
    _require(bodies.length == 1, 'Expected one ACBF body');
    final nodes = _children(bodies.single, 'page').toList();
    _require(
      nodes.isNotEmpty && nodes.length <= limits.pages,
      'Invalid subtitle page count',
    );
    final bindings = manifest == null
        ? null
        : _manifest(manifest, bytes, nodes.length);
    final pages = <SubtitlePage>[];
    final pageIds = <String>{}, dialogueIds = <String>{};
    var count = 0;
    for (final (index, node) in nodes.indexed) {
      final images = _children(node, 'image');
      _require(images.length == 1, 'Expected one page image');
      final href = _identifier(images.single.getAttribute('href'));
      final isEmbedded = href.startsWith('#');
      _require(
        isEmbedded || _relative(href),
        'Expected a local relative image name',
      );
      final image = isEmbedded ? embedded[href.substring(1)] : null;
      _require(!isEmbedded || image != null, 'Missing embedded image');
      final binding = bindings?[index];
      final id = binding == null
          ? 'page-${index + 1}'
          : _identifier(binding['id']);
      _require(pageIds.add(id), 'Duplicate subtitle page ID');
      final digest = binding == null
          ? image?.digest
          : _identifier(binding['sha256']);
      if (digest != null) {
        _require(
          RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) &&
              (image == null || image.digest == digest),
          'Page digest mismatch',
        );
      }
      int? width = image?.width, height = image?.height;
      if (binding != null) {
        final size = binding['size'];
        _require(
          size is List && size.length == 2 && size.every((part) => part is int),
          'Invalid page size',
        );
        width = (size as List)[0] as int;
        height = size[1] as int;
        _checkSize(width, height, limits);
        _require(
          image == null || (width == image.width && height == image.height),
          'Page size mismatch',
        );
      }
      final ids = binding?['layers'];
      _require(binding == null || ids is Map, 'Missing language bindings');
      final languages = <String>{}, localIds = <String>{};
      final areas = <SubtitleArea>[];
      final geometry = <String, List<int>>{};
      for (final layer in _children(node, 'text-layer')) {
        final language = _identifier(layer.getAttribute('lang'));
        _require(languages.add(language), 'Duplicate language layer');
        final regions = _children(layer, 'text-area').toList();
        count += regions.length;
        _require(count <= limits.areas, 'Too many subtitle regions');
        final keys = (ids as Map?)?[language];
        _require(
          binding == null || (keys is List && keys.length == regions.length),
          'Language regions do not match the manifest',
        );
        for (final (position, region) in regions.indexed) {
          final points = region.getAttribute('points');
          final bounds = _bounds(points, width, height);
          final text = _children(
            region,
            'p',
          ).map((para) => para.innerText).join('\n');
          _require(
            text.length <= limits.textLength,
            'Subtitle text exceeds the limit',
          );
          final key = keys == null
              ? '$id-$language-${position + 1}'
              : _identifier(keys[position]);
          localIds.add(key);
          if (keys == null) {
            (geometry[points!.trim().split(RegExp(r'\s+')).join(' ')] ??= [])
                .add(areas.length);
          }
          areas.add(SubtitleArea(key, language, text, bounds));
        }
      }
      for (final group in geometry.values) {
        if (group.length < 2 ||
            group.map((index) => areas[index].language).toSet().length !=
                group.length) {
          continue;
        }
        final key = areas[group.first].dialogue;
        for (final index in group.skip(1)) {
          final area = areas[index];
          areas[index] = SubtitleArea(
            key,
            area.language,
            area.text,
            area.bounds,
          );
        }
      }
      _require(
        ids == null || (ids as Map).length == languages.length,
        'Unexpected language bindings',
      );
      _require(
        localIds.every(dialogueIds.add),
        'Dialogue ID occurs on different pages',
      );
      final original = binding == null
          ? languages.firstOrNull
          : _identifier(binding['sourceLanguage']);
      _require(
        languages.isEmpty || languages.contains(original),
        'Missing source language',
      );
      pages.add(
        SubtitlePage(
          id,
          href,
          digest,
          original,
          List.unmodifiable(areas),
          width,
          height,
        ),
      );
    }
    return SubtitleDocument(List.unmodifiable(pages));
  }
}

Iterable<XmlElement> _children(XmlElement element, String name) =>
    element.findElements(name, namespace: subtitleNamespace);

String _identifier(Object? value) {
  _require(
    value is String && value.trim().isNotEmpty && value.length <= 512,
    'Invalid subtitle identifier',
  );
  return value as String;
}

bool _relative(String href) =>
    !href.contains(RegExp(r'[:\\%?#\x00-\x1f]')) &&
    href
        .split('/')
        .every((part) => part.isNotEmpty && part != '.' && part != '..');

void _checkSize(int width, int height, SubtitleLimits limits) => _require(
  width > 0 && height > 0 && width <= limits.pixels ~/ height,
  'Page exceeds the pixel limit',
);

List<Map<String, dynamic>> _manifest(
  Uint8List manifest,
  Uint8List bytes,
  int count,
) {
  final value = jsonDecode(utf8.decode(manifest));
  _require(
    value is Map &&
        value['profile'] == 'venera-subtitles-experiment-1' &&
        value['acbfSha256'] == sha256.convert(bytes).toString(),
    'Manifest does not match this ACBF revision',
  );
  final pages = value['pages'];
  _require(
    pages is List &&
        pages.length == count &&
        pages.every((page) => page is Map<String, dynamic>),
    'Manifest page list does not match',
  );
  return (pages as List).cast<Map<String, dynamic>>();
}

SubtitleBounds _bounds(String? points, int? width, int? height) {
  final vertices = (points ?? '').trim().split(RegExp(r'\s+'));
  _require(
    vertices.length >= 3 && vertices.length <= 256,
    'Invalid subtitle polygon',
  );
  var left = 0x7fffffff, right = 0, top = 0x7fffffff, bottom = 0;
  for (final vertex in vertices) {
    final pair = vertex.split(',');
    _require(pair.length == 2, 'Invalid subtitle point');
    final horizontal = int.parse(pair.first), vertical = int.parse(pair.last);
    _require(
      horizontal >= 0 &&
          horizontal <= (width ?? 0x7fffffff) &&
          vertical >= 0 &&
          vertical <= (height ?? 0x7fffffff),
      'Subtitle point outside page',
    );
    left = math.min(left, horizontal);
    right = math.max(right, horizontal);
    top = math.min(top, vertical);
    bottom = math.max(bottom, vertical);
  }
  _require(right > left && bottom > top, 'Empty subtitle region');
  return (left: left, top: top, right: right, bottom: bottom);
}
