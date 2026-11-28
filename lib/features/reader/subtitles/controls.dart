import 'dart:async';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/translations.dart';

import '../reader_page.dart';
import 'binding.dart';
import 'mount_dialog.dart';
import 'overlay.dart';
import 'reading.dart';
import 'store.dart';

Future<ChapterSubtitleIndex> loadReadingSubtitles(
  SubtitleStore store,
  String book,
  String chapter,
) async {
  final revision = await Isolate.run(() => store.read(book, chapter));
  if (revision == null) return ChapterSubtitleIndex(chapter, []);
  final files = await LocalManager().getImages(book, ComicType.local, chapter);
  final indexed = await scanSubtitleChapter(files);
  return Isolate.run(
    () => ChapterSubtitleIndex(
      chapter,
      bindSubtitlePages(revision.parse(), indexed, revision.choices),
    ),
  );
}

class ReaderSubtitleControls extends StatelessWidget {
  const ReaderSubtitleControls({
    super.key,
    required this.reader,
    required this.display,
    required this.store,
  });
  final ReaderState reader;
  final SubtitleDisplay display;
  final SubtitleStore store;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Chapter subtitles'.tl,
    icon: const Icon(Icons.subtitles_outlined),
    onPressed: () => _open(context),
  );

  Future<void> _open(BuildContext context) async {
    final book = reader.cid, chapter = reader.eid, path = App.dataPath;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final images = List<String>.of(reader.images ?? const []);
    bool current() =>
        reader.mounted &&
        reader.type == ComicType.local &&
        reader.cid == book &&
        App.dataPath == path;
    display.startNavigation();
    final release = reader.acquireAutomaticReadingPause();
    try {
      final hit = await showDialog<SubtitleHit>(
        context: context,
        builder: (_) => _SubtitlePanel(
          display: display,
          chapters: store.chapters(book),
          title: (id) => reader.widget.chapters?[id] ?? reader.widget.name,
          mount: (panelContext) async {
            final saved = await showDialog<bool>(
              context: panelContext,
              builder: (_) => SubtitleMountDialog(
                store: store,
                book: book,
                chapter: chapter,
                images: images,
                isCurrent: () => current() && reader.eid == chapter,
              ),
            );
            if (saved == true && current()) display.refresh();
            return store.chapters(book);
          },
        ),
      );
      if (hit == null || !current()) return;
      final navigation = display.startNavigation();
      final number =
          (reader.widget.chapters?.ids.toList() ?? ['0']).indexOf(hit.chapter) +
          1;
      if (number == 0) return;
      final shell = reader.scaffoldKey.currentState;
      if (shell?.isOpen == true) shell!.openOrClose();
      if (reader.eid != hit.chapter && !reader.toChapter(number)) return;
      var reached = reader.eid == hit.chapter;
      final deadline = Stopwatch()..start();
      while (current() &&
          display.acceptsNavigation(navigation) &&
          deadline.elapsed < const Duration(seconds: 10)) {
        if (reader.eid != hit.chapter && (reached || reader.eid != chapter)) {
          return;
        }
        reached |= reader.eid == hit.chapter;
        if (reader.eid == hit.chapter &&
            !reader.controller.content.isLoading &&
            reader.imageViewController != null &&
            reader.images?.elementAtOrNull(hit.file.number - 1) ==
                'file://${hit.file.path}') {
          reader.toPage(
            reader.pageLayout.pageForImage(hit.file.number),
            animated: false,
          );
          display.highlight(hit);
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 32));
      }
      if (current() &&
          display.acceptsNavigation(navigation) &&
          messenger?.mounted == true) {
        messenger!.showSnackBar(SnackBar(content: Text('Page not found'.tl)));
      }
    } finally {
      release();
    }
  }
}

class _SubtitlePanel extends StatefulWidget {
  const _SubtitlePanel({
    required this.display,
    required this.chapters,
    required this.mount,
    required this.title,
  });
  final SubtitleDisplay display;
  final List<String> chapters;
  final String Function(String) title;
  final Future<List<String>> Function(BuildContext) mount;
  @override
  State<_SubtitlePanel> createState() => _SubtitlePanelState();
}

class _SubtitlePanelState extends State<_SubtitlePanel> {
  String _query = '';
  late List<String> _chapters = widget.chapters;
  bool _loading = true;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    for (final chapter in _chapters) {
      if (!mounted) return;
      await widget.display.ensure(chapter);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.display,
    builder: (context, _) {
      final display = widget.display;
      final languages = {
        for (final index in display.indexes.values) ...index.languages,
      };
      final hits = [
        for (final chapter in _chapters)
          ...?display.indexes[chapter]?.search(_query, display.language),
      ];
      return AlertDialog(
        title: Text('Chapter subtitles'.tl),
        content: SizedBox(
          width: 450,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                title: Text('Show subtitles'.tl),
                value: display.visible,
                onChanged: (value) =>
                    display.configure(value, display.language),
              ),
              if (languages.isNotEmpty)
                DropdownButton<String>(
                  isExpanded: true,
                  value: languages.contains(display.language)
                      ? display.language
                      : '',
                  items: [
                    DropdownMenuItem(value: '', child: Text('Automatic'.tl)),
                    for (final language in languages)
                      DropdownMenuItem(value: language, child: Text(language)),
                  ],
                  onChanged: (value) =>
                      display.configure(true, value == '' ? null : value),
                ),
              TextField(
                decoration: InputDecoration(
                  labelText: 'Search'.tl,
                  prefixIcon: const Icon(Icons.search),
                ),
                onChanged: (text) => setState(() => _query = text),
              ),
              if (_loading) const LinearProgressIndicator(),
              if (display.loadError != null) Text(display.loadError!),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: hits.length,
                  itemBuilder: (context, index) {
                    final hit = hits[index];
                    return ListTile(
                      title: Text(hit.area.text),
                      subtitle: Text(
                        '${widget.title(hit.chapter)} · ${'Page'.tl} ${hit.file.number}',
                      ),
                      onTap: () => Navigator.pop(context, hit),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final chapters = await widget.mount(context);
              if (mounted) {
                setState(() {
                  _chapters = chapters;
                  _loading = true;
                });
                await _load();
              }
            },
            child: Text('Manage subtitles'.tl),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Close'.tl),
          ),
        ],
      );
    },
  );
}
