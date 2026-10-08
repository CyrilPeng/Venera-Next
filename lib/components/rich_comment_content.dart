import 'package:venera_next/foundation/comment_markup.dart';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/image_provider/cached_image.dart';
import 'package:venera_next/routing/app_links.dart';
import 'package:venera_next/foundation/extensions.dart';
import 'package:venera_next/foundation/widget_utils.dart';

import 'gesture.dart';

/// Opens a comment link while retaining ownership of the originating route.
Future<void> openCommentLink(
  BuildContext context,
  String link, {
  Future<bool> Function(Uri, bool Function())? openAppLink,
  Future<bool> Function(String)? openExternal,
  bool Function()? isActive,
}) async {
  bool active() => context.mounted && (isActive?.call() ?? true);
  if (!active() || !link.isURL) return;
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = ModalRoute.of(context);
  try {
    final handled = await (openAppLink == null
        ? handleAppLink(Uri.parse(link), isActive: active)
        : openAppLink(Uri.parse(link), active));
    if (!active()) return;
    if (handled) {
      // The app link may already have pushed another route. Only remove the
      // original root overlay, never pop whichever route is now on top.
      if (navigator.mounted &&
          route != null &&
          route.navigator == navigator &&
          route.isActive &&
          !route.isFirst) {
        navigator.removeRoute(route);
      }
    } else {
      await (openExternal?.call(link) ?? launchUrlString(link));
    }
  } catch (error, stack) {
    Log.error('Comment link', error.toString(), stack);
  }
}

/// A widget that displays comment content with support for rich text formatting.
///
/// This widget intelligently decides whether to use simple text or rich formatting
/// based on the content. It supports HTML tags and auto-linking of URLs.
class CommentContent extends StatelessWidget {
  const CommentContent({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    if (!text.contains('<') && !text.contains('http')) {
      return SelectableText(text);
    } else {
      return RichCommentContent(text: text);
    }
  }
}

extension _CommentTagStyle on CommentTag {
  TextSpan merge(
    TextSpan s,
    BuildContext context,
    TapGestureRecognizer Function(String) createLink,
  ) {
    var style = s.style ?? ts;
    style = switch (name) {
      'b' => style.bold,
      'i' => style.italic,
      'u' => style.underline,
      's' => style.lineThrough,
      'a' => style.withColor(context.colorScheme.primary),
      'strong' => style.bold,
      'span' => () {
        if (attributes.containsKey('style')) {
          var s = attributes['style']!;
          var css = s.split(';');
          for (var c in css) {
            var kv = c.split(':');
            if (kv.length == 2) {
              var key = kv[0].trim();
              var value = kv[1].trim();
              switch (key) {
                case 'color':
                  // Color is not supported, we should make text display well in light and dark mode.
                  break;
                case 'font-weight':
                  if (value == 'bold') {
                    style = style.bold;
                  } else if (value == 'lighter') {
                    style = style.light;
                  }
                  break;
                case 'font-style':
                  if (value == 'italic') {
                    style = style.italic;
                  }
                  break;
                case 'text-decoration':
                  if (value == 'underline') {
                    style = style.underline;
                  } else if (value == 'line-through') {
                    style = style.lineThrough;
                  }
                  break;
                case 'font-size':
                  // Font size is not supported.
                  break;
              }
            }
          }
        }
        return style;
      }(),
      _ => style,
    };
    if (style.color != null) {
      style = style.copyWith(decorationColor: style.color);
    }
    var recognizer = s.recognizer;
    if (name == 'a') {
      var link = attributes['href'];
      if (link != null && link.isURL) {
        recognizer = createLink(link);
      }
    }
    return TextSpan(text: s.text, style: style, recognizer: recognizer);
  }
}

class RichCommentContent extends StatefulWidget {
  const RichCommentContent({
    super.key,
    required this.text,
    this.showImages = true,
  });

  final String text;

  final bool showImages;

  @override
  State<RichCommentContent> createState() => _RichCommentContentState();
}

class _RichCommentContentState extends State<RichCommentContent> {
  var textSpan = <InlineSpan>[];
  List<CommentImage> images = const [];
  final _recognizers = <TapGestureRecognizer>[];
  int _generation = 0;

  void _releaseRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  TapGestureRecognizer _createLink(String link) {
    final generation = _generation;
    final recognizer = TapGestureRecognizer()
      ..onTap = () {
        if (!mounted || generation != _generation) return;
        openCommentLink(
          context,
          link,
          isActive: () => mounted && generation == _generation,
        );
      };
    _recognizers.add(recognizer);
    return recognizer;
  }

  @override
  void didUpdateWidget(RichCommentContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) render();
  }

  @override
  void dispose() {
    _generation++;
    _releaseRecognizers();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    render();
  }

  void render() {
    _generation++;
    _releaseRecognizers();
    textSpan.clear();
    images = const [];
    final markup = parseCommentMarkup(widget.text);
    images = markup.images;
    for (final run in markup.textRuns) {
      if (run.isAutoLink) {
        textSpan.add(
          TextSpan(
            text: run.text,
            style: ts.withColor(context.colorScheme.primary),
            recognizer: _createLink(run.text),
          ),
        );
      } else {
        var span = TextSpan(text: run.text);
        for (final tag in run.tags) {
          span = tag.merge(span, context, _createLink);
        }
        textSpan.add(span);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget content = SelectableText.rich(
      TextSpan(style: DefaultTextStyle.of(context).style, children: textSpan),
    );
    if (images.isNotEmpty && widget.showImages) {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          content,
          Wrap(
            runSpacing: 4,
            spacing: 4,
            children: images.map((e) {
              Widget image = Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                ),
                width: 100,
                height: 100,
                child: Image(
                  width: 100,
                  height: 100,
                  image: CachedImageProvider(e.url),
                ),
              );
              if (e.link != null) {
                image = ClickInkWell(
                  onTap: () {
                    openCommentLink(context, e.link!, isActive: () => mounted);
                  },
                  child: image,
                );
              }
              return image;
            }).toList(),
          ),
        ],
      );
    }
    return content;
  }
}
