import 'dart:collection';

import 'package:venera_next/foundation/extensions/string_extensions.dart';

/// Parsed comment content. Styling, gesture recognizers and navigation belong
/// to the renderer; this model contains only text, tag attributes and images.
class CommentMarkup {
  CommentMarkup(
    Iterable<CommentTextRun> textRuns,
    Iterable<CommentImage> images,
  ) : textRuns = List.unmodifiable(textRuns),
      images = List.unmodifiable(images);

  final List<CommentTextRun> textRuns;
  final List<CommentImage> images;
}

class CommentTag {
  CommentTag(this.name, Map<String, String> attributes)
    : attributes = Map.unmodifiable(attributes);

  final String name;
  final Map<String, String> attributes;
}

class CommentTextRun {
  CommentTextRun(
    this.text, {
    Iterable<CommentTag> tags = const [],
    this.isAutoLink = false,
  }) : tags = List.unmodifiable(tags);

  final String text;
  final List<CommentTag> tags;
  // The legacy renderer styles automatic URLs independently of enclosing tags.
  final bool isAutoLink;
}

class CommentImage {
  const CommentImage(this.url, this.link);

  final String url;
  final String? link;
}

/// Parse the existing comment markup dialect without a Widget tree.
/// This deliberately retains its tag/attribute matching and URL rules rather
/// than replacing them with a general HTML parser.
CommentMarkup parseCommentMarkup(String text) {
  final textRuns = <CommentTextRun>[];
  final images = <CommentImage>[];
  bool isValidUrlChar(String char) {
    return RegExp(r'[a-zA-Z0-9%:/.@\-_?&=#*!+;]').hasMatch(char);
  }

  var s = Queue<CommentTag>();

  int i = 0;
  var buffer = StringBuffer();
  text = text.replaceAll('\r\n', '\n');
  text = text.replaceAll('&amp;', '&');

  void writeBuffer() {
    if (buffer.isEmpty) return;
    textRuns.add(CommentTextRun(buffer.toString(), tags: s));
    buffer.clear();
  }

  while (i < text.length) {
    if (text[i] == '<' && i != text.length - 1) {
      if (text[i + 1] != '/') {
        // start tag
        var j = text.indexOf('>', i);
        if (j != -1) {
          var tagContent = text.substring(i + 1, j);
          var splits = tagContent.split(' ');
          splits.removeWhere((element) => element.isEmpty);
          var tagName = splits[0];
          var attributes = <String, String>{};
          for (var k = 1; k < splits.length; k++) {
            var attr = splits[k];
            var attrSplits = attr.split('=');
            if (attrSplits.length == 2) {
              attributes[attrSplits[0]] = attrSplits[1].replaceAll('"', '');
            }
          }
          const acceptedTags = [
            'img',
            'a',
            'b',
            'i',
            'u',
            's',
            'br',
            'span',
            'strong',
          ];
          if (acceptedTags.contains(tagName)) {
            writeBuffer();
            if (tagName == 'img') {
              var url = attributes['src'];
              String? link;
              for (var tag in s) {
                if (tag.name == 'a') {
                  link = tag.attributes['href'];
                  break;
                }
              }
              if (url != null) {
                images.add(CommentImage(url, link));
              }
            } else if (tagName == 'br') {
              buffer.write('\n');
            } else {
              s.add(CommentTag(tagName, attributes));
            }
            i = j + 1;
            continue;
          }
        }
      } else {
        // end tag
        var j = text.indexOf('>', i);
        if (j != -1) {
          var tagContent = text.substring(i + 2, j);
          var splits = tagContent.split(' ');
          splits.removeWhere((element) => element.isEmpty);
          var tagName = splits[0];
          if (s.isNotEmpty && s.last.name == tagName) {
            writeBuffer();
            s.removeLast();
            i = j + 1;
            continue;
          }
          if (tagName == 'br') {
            i = j + 1;
            buffer.write('\n');
            continue;
          }
        }
      }
    } else if (text.length - i > 8 &&
        text.substring(i, i + 4) == 'http' &&
        !s.any((e) => e.name == 'a')) {
      // auto link
      int j = i;
      for (; j < text.length; j++) {
        if (!isValidUrlChar(text[j])) {
          break;
        }
      }
      var url = text.substring(i, j);
      if (url.isURL) {
        writeBuffer();
        textRuns.add(CommentTextRun(url, isAutoLink: true));
        i = j;
        continue;
      }
    }
    buffer.write(text[i]);
    i++;
  }
  writeBuffer();
  return CommentMarkup(textRuns, images);
}
