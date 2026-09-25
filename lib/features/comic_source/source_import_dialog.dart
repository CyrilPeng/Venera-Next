import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/network/app_dio.dart';

import 'source.dart';
import 'source_import.dart';
import 'source_installation.dart';
import 'source_repositories.dart';

class SourceImportDialog extends StatefulWidget {
  const SourceImportDialog({super.key, this.client});
  final Dio? client;

  @override
  State<SourceImportDialog> createState() => _SourceImportDialogState();
}

class _SourceImportDialogState extends State<SourceImportDialog> {
  final _input = TextEditingController();
  final _baseUrl = TextEditingController();
  final _repositoryName = TextEditingController();
  final _cancel = CancelToken();
  SourceImportPreview? _preview;
  String? _contents, _fileName, _error;
  Future<Uint8List> Function()? _readFile;
  bool _needsBase = false,
      _busy = false,
      _installing = false,
      _saveRepository = true;
  final _selected = <String>{};

  @override
  void dispose() {
    _cancel.cancel();
    _input.dispose();
    _baseUrl.dispose();
    _repositoryName.dispose();
    super.dispose();
  }

  void _showPreview(SourceImportPreview preview) {
    _preview = preview;
    _repositoryName.text = preview.name;
    _selected.clear();
    for (final entry in preview.catalog?.entries ?? <SourceCatalogEntry>[]) {
      if (ComicSource.find(entry.key) == null) _selected.add(entry.key);
    }
  }

  Future<void> _identify() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final input = _input.text.trim();
      final SourceImportPreview preview;
      if (_contents == null &&
          RegExp(r'^https?://', caseSensitive: false).hasMatch(input)) {
        preview = await SourceImportPreview.fromUrl(
          input,
          client: widget.client,
          cancelToken: _cancel,
        );
      } else {
        _contents ??= input;
        preview = SourceImportPreview.parse(
          _contents!,
          fileName: _fileName,
          baseUrl: _baseUrl.text.trim().isEmpty ? null : _baseUrl.text.trim(),
        );
      }
      if (!mounted) return;
      setState(() => _showPreview(preview));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _needsBase = _needsBase || error is SourceImportNeedsBaseUrl;
        _error = error.toString();
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseFile() async {
    final file = await selectFile(ext: ['js', 'json']);
    if (file == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final contents = utf8.decode(await file.readAsBytes());
      if (!mounted) return;
      _contents = contents;
      _fileName = file.name;
      _readFile = file.readAsBytes;
      await _identify();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _install() async {
    final preview = _preview!;
    setState(() {
      _installing = true;
      _error = null;
    });
    try {
      final queue = SourceInstallations.instance;
      if (preview.catalog == null) {
        queue.enqueuePreviewedScript(
          name: preview.name,
          contents: preview.contents,
          url: preview.url,
          readFile: _readFile,
        );
      } else {
        SourceRepository? repository;
        if (_saveRepository && preview.url != null) {
          repository = SourceRepositories.instance.all
              .where((r) => r.url == preview.url)
              .firstOrNull;
          repository ??= await SourceRepositories.instance.save(
            name: _repositoryName.text,
            url: preview.url!,
            catalogContents: preview.contents,
          );
        }
        for (final entry in preview.catalog!.entries) {
          if (!_selected.contains(entry.key) ||
              ComicSource.find(entry.key) != null) {
            continue;
          }
          if (repository == null) {
            queue.enqueueCatalogEntry(entry);
          } else {
            queue.enqueueRepository(repository, entry);
          }
        }
      }
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  void _reset() => setState(() {
    _preview = null;
    _contents = _fileName = _error = null;
    _readFile = null;
    _needsBase = false;
    _baseUrl.clear();
  });

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final catalog = preview?.catalog;
    final canSaveRepository = catalog != null && preview?.url != null;
    return PopScope(
      canPop: !_installing,
      child: AlertDialog(
        title: Text('Add source'.tl),
        content: SizedBox(
          width: 600,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.65,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (preview == null) ...[
                    Text(
                      'Paste a link or contents, or choose a JS/JSON file. The source type will be detected automatically.'
                          .tl,
                    ),
                    const SizedBox(height: 16),
                    if (_fileName == null)
                      TextField(
                        controller: _input,
                        enabled: !_busy,
                        minLines: 2,
                        maxLines: 5,
                        autocorrect: false,
                        decoration: InputDecoration(
                          labelText: 'Source link or contents'.tl,
                          hintText: 'https://example.com/sources.json',
                        ),
                        onChanged: (_) {
                          _contents = null;
                        },
                      )
                    else
                      TextButton(
                        onPressed: _busy ? null : _reset,
                        child: Text(
                          '${_fileName!} · ${'Choose another source'.tl}',
                        ),
                      ),
                    if (_needsBase) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: _baseUrl,
                        enabled: !_busy,
                        decoration: InputDecoration(
                          labelText: 'Original source list URL'.tl,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _chooseFile,
                      icon: const Icon(Icons.file_open_outlined),
                      label: Text('Choose JS or JSON file'.tl),
                    ),
                  ] else ...[
                    Text(
                      catalog == null
                          ? 'Source script detected'.tl
                          : 'Source list detected: @count sources'.tlParams({
                              'count': catalog.entries.length,
                            }),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (catalog == null) ...[
                      const SizedBox(height: 12),
                      Text(preview.name),
                      if (preview.url != null) SelectableText(preview.url!),
                    ] else ...[
                      if (catalog.skipped.isNotEmpty)
                        Text(
                          'Skipped invalid entries: @entries'.tlParams({
                            'entries': catalog.skipped.join(', '),
                          }),
                        ),
                      if (canSaveRepository) ...[
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text('Save as a source repository'.tl),
                          subtitle: Text(
                            'Keep this list for future browsing and update checks.'
                                .tl,
                          ),
                          value: _saveRepository,
                          onChanged: _installing
                              ? null
                              : (value) =>
                                    setState(() => _saveRepository = value!),
                        ),
                        if (_saveRepository)
                          TextField(
                            controller: _repositoryName,
                            enabled: !_installing,
                            decoration: InputDecoration(
                              labelText: 'Repository name'.tl,
                            ),
                          ),
                      ],
                      TextButton(
                        onPressed: _installing
                            ? null
                            : () => setState(() {
                                if (_selected.isNotEmpty) {
                                  _selected.clear();
                                } else {
                                  _selected.addAll(
                                    catalog.entries
                                        .where(
                                          (e) =>
                                              ComicSource.find(e.key) == null,
                                        )
                                        .map((e) => e.key),
                                  );
                                }
                              }),
                        child: Text(
                          _selected.isEmpty
                              ? 'Select all'.tl
                              : 'Deselect all'.tl,
                        ),
                      ),
                      for (final entry in catalog.entries)
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(entry.name),
                          subtitle: Text(
                            ComicSource.find(entry.key) != null
                                ? 'Installed'.tl
                                : '${entry.key} · ${entry.version}',
                          ),
                          value: _selected.contains(entry.key),
                          onChanged:
                              _installing || ComicSource.find(entry.key) != null
                              ? null
                              : (value) => setState(() {
                                  value!
                                      ? _selected.add(entry.key)
                                      : _selected.remove(entry.key);
                                }),
                        ),
                    ],
                    TextButton(
                      onPressed: _installing ? null : _reset,
                      child: Text('Choose another source'.tl),
                    ),
                  ],
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (_busy || _installing) const LinearProgressIndicator(),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _installing ? null : () => Navigator.pop(context),
            child: Text('Cancel'.tl),
          ),
          if (preview == null)
            FilledButton(
              onPressed: _busy ? null : _identify,
              child: Text('Detect and preview'.tl),
            )
          else
            FilledButton(
              onPressed:
                  _installing ||
                      (catalog != null &&
                          _selected.isEmpty &&
                          !(canSaveRepository && _saveRepository))
                  ? null
                  : _install,
              child: Text(
                catalog == null
                    ? 'Install source'.tl
                    : _selected.isEmpty
                    ? 'Save repository'.tl
                    : 'Install selected (@count)'.tlParams({
                        'count': _selected.length,
                      }),
              ),
            ),
        ],
      ),
    );
  }
}
