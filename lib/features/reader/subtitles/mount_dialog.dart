import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/foundation/translations.dart';

import 'binding.dart';
import 'archive.dart';
import 'document.dart';
import 'store.dart';

Future<List<SubtitleFile>> scanSubtitleChapter(List<String> images) =>
    Isolate.run(() => overrideIO(() => fingerprintSubtitleImages(images)));

Future<Uint8List?> _pickBytes(String extension) async {
  final selection = await selectFile(ext: [extension]);
  if (selection == null) return null;
  return withSelectedFile(
    selection,
    (chosen) => chosen.withFile((file) async {
      final handle = await file.open();
      try {
        final limit = const SubtitleLimits().bytes;
        if (await handle.length() > limit) {
          throw const FormatException('Subtitle file exceeds the size limit');
        }
        final result = BytesBuilder(copy: false);
        while (true) {
          final chunk = await handle.read(65536);
          if (chunk.isEmpty) return result.takeBytes();
          if (result.length + chunk.length > limit) {
            throw const FormatException('Subtitle file exceeds the size limit');
          }
          result.add(chunk);
        }
      } finally {
        await handle.close();
      }
    }),
  );
}

class SubtitleMountDialog extends StatefulWidget {
  const SubtitleMountDialog({
    super.key,
    required this.store,
    required this.book,
    required this.chapter,
    required this.images,
    required this.isCurrent,
  });
  final SubtitleStore store;
  final String book, chapter;
  final List<String> images;
  final bool Function() isCurrent;
  @override
  State<SubtitleMountDialog> createState() => _SubtitleMountDialogState();
}

class _SubtitleMountDialogState extends State<SubtitleMountDialog> {
  late final Future<List<SubtitleFile>> _files;
  SubtitleRevision? _revision;
  String? _originalToken;
  SubtitleDocument? _document;
  List<SubtitleBinding> _bindings = [];
  bool _busy = true;
  String? _error;
  Directory? _archiveDirectory;

  @override
  void initState() {
    super.initState();
    _files = scanSubtitleChapter(widget.images);
    _run(() async {
      final files = await _files;
      if (!mounted) return;
      if (files.isNotEmpty) {
        final directory = File(files.first.path).parent;
        if (File('${directory.path}/book.pages.json').existsSync() &&
            File('${directory.path}/book.acbf').existsSync()) {
          _archiveDirectory = directory;
        }
      }
      final current = widget.store.read(widget.book, widget.chapter);
      _originalToken = current?.token;
      if (current != null) await _prepare(current);
    });
  }

  Future<void> _run(Future<void> Function() task) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await task();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _prepare(SubtitleRevision revision) async {
    final document = await Isolate.run(revision.parse);
    final files = await _files;
    if (!mounted) return;
    _revision = revision;
    _document = document;
    _bindings = bindSubtitlePages(document, files, revision.choices);
  }

  Future<void> _pick(bool manifest) => _run(() async {
    final content = await _pickBytes(manifest ? 'json' : 'acbf');
    if (content == null || !mounted) return;
    final previous = _revision;
    await _prepare(
      SubtitleRevision(
        manifest ? previous!.acbf : content,
        manifest ? content : null,
        manifest ? previous!.choices : {},
        null,
      ),
    );
  });

  Future<void> _export() => _run(() async {
    final revision = _revision!;
    final bindings = _bindings;
    final chapter = await _files;
    if (chapter.length != widget.images.length) {
      throw const FormatException('An original chapter image is missing');
    }
    await SelectionOperation().run(
      (operation) => operation.useTemporaryDirectory(
        cacheDirectory: Directory(App.cachePath),
        consume: (workspace) async {
          final file = await Isolate.run(
            () => writeSubtitleArchive(workspace, revision, bindings, chapter),
          );
          if (mounted && widget.isCurrent()) {
            await saveFile(
              operation: operation,
              file: file,
              filename: 'chapter.cbz',
            );
          }
        },
      ),
    );
  });

  Future<void> _choose(SubtitleBinding binding) async {
    final file = await showDialog<SubtitleFile>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Choose original page'.tl),
        children: [
          SizedBox(
            width: 420,
            height: 320,
            child: ListView.builder(
              itemCount: binding.candidates.length,
              itemBuilder: (context, index) {
                final file = binding.candidates[index];
                return ListTile(
                  leading: Image.file(
                    File(file.path),
                    width: 56,
                    cacheWidth: 112,
                    errorBuilder: (_, _, _) =>
                        const Icon(Icons.broken_image_outlined),
                  ),
                  title: Text(subtitleFileLabel(file)),
                  onTap: () => Navigator.pop(context, file),
                );
              },
            ),
          ),
        ],
      ),
    );
    if (file == null || !mounted) return;
    final files = await _files;
    if (!mounted) return;
    final choices = {
      ..._revision!.choices,
      binding.page.id: (path: file.path, digest: file.digest),
    };
    final revision = _revision!;
    setState(() {
      _revision = SubtitleRevision(
        revision.acbf,
        revision.manifest,
        choices,
        revision.token,
      );
      _bindings = bindSubtitlePages(_document!, files, choices);
    });
  }

  void _apply({bool detach = false}) {
    if (!widget.isCurrent()) {
      Navigator.pop(context);
      return;
    }
    try {
      final draft = _revision;
      final choices = <String, SubtitleChoice>{...?draft?.choices};
      for (final binding in _bindings) {
        if (binding.selected case final selected?) {
          choices[binding.page.id] = (
            path: selected.path,
            digest: selected.digest,
          );
        }
      }
      widget.store.replace(
        widget.book,
        widget.chapter,
        _originalToken,
        detach
            ? null
            : SubtitleRevision(draft!.acbf, draft.manifest, choices, null),
      );
      Navigator.pop(context, true);
    } catch (error) {
      setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Chapter subtitles'.tl),
    content: SizedBox(
      width: 480,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            children: [
              TextButton(
                onPressed: _busy ? null : () => _pick(false),
                child: Text('Select ACBF'.tl),
              ),
              if (_revision != null)
                TextButton(
                  onPressed: _busy ? null : () => _pick(true),
                  child: Text('Add page manifest'.tl),
                ),
              if (_archiveDirectory != null)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          final revision = await readArchivedSubtitles(
                            _archiveDirectory!,
                          );
                          if (revision != null && mounted) {
                            await _prepare(revision);
                          }
                        }),
                  child: Text('Load archived subtitles'.tl),
                ),
              if (_revision?.manifest != null &&
                  _bindings.isNotEmpty &&
                  _bindings.every((binding) => binding.selected != null))
                TextButton(
                  onPressed: _busy ? null : _export,
                  child: Text('Export chapter with subtitles'.tl),
                ),
            ],
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _bindings.length,
              itemBuilder: (context, index) {
                final item = _bindings[index], chosen = item.selected;
                return ListTile(
                  title: Text('${index + 1} · ${item.page.image}'),
                  subtitle: Text(
                    chosen != null
                        ? subtitleFileLabel(chosen)
                        : item.candidates.isEmpty
                        ? 'Page not found'.tl
                        : 'Choose original page'.tl,
                  ),
                  trailing: Icon(
                    chosen != null ? Icons.check : Icons.help_outline,
                  ),
                  onTap: _busy || item.candidates.isEmpty
                      ? null
                      : () => _choose(item),
                );
              },
            ),
          ),
        ],
      ),
    ),
    actions: [
      if (_originalToken != null)
        TextButton(
          onPressed: _busy ? null : () => _apply(detach: true),
          child: Text('Detach subtitles'.tl),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text('Cancel'.tl),
      ),
      FilledButton(
        onPressed: _busy || _document == null || _error != null ? null : _apply,
        child: Text('Save'.tl),
      ),
    ],
  );
}
