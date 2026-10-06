import 'dart:async';
import 'source_failure.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'source_failure_presentation.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/network/app_dio.dart';

import 'source_import.dart';
import 'source_inspection_task.dart';
import 'package:venera_next/network/request_scope.dart';
import 'package:venera_next/foundation/log.dart';
import 'source_installations_scope.dart';
import 'source_repositories.dart';

class SourceImportDialog extends StatefulWidget {
  const SourceImportDialog({super.key, this.createClient, this.pickFile});
  final Dio Function()? createClient;
  final Future<FileSelection?> Function()? pickFile;

  @override
  State<SourceImportDialog> createState() => _SourceImportDialogState();
}

class _SourceImportDialogState extends SettingsSaveState<SourceImportDialog> {
  final _input = TextEditingController();
  final _baseUrl = TextEditingController();
  final _repositoryName = TextEditingController();
  SourceInspectionTask<void>? _inspection;
  SourceSelectionOwner? _selectionOwner;
  SourceImportPreview? _preview;
  String? _contents, _fileName, _error;
  Future<Uint8List> Function()? _readFile;
  bool _needsBase = false, _busy = false, _saveRepository = true;
  final _selected = <String>{};
  bool get _installing => savingSettings || hasSettingsSaveError;

  @override
  void dispose() {
    _inspection?.cancel();
    _selectionOwner?.release();
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
      if (SourceInstallationsScope.of(context).manager.find(entry.key) ==
          null) {
        _selected.add(entry.key);
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_inspection?.sameWindow == false) _inspection?.cancel();
  }

  @override
  void didUpdateWidget(covariant SourceImportDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.createClient != widget.createClient ||
        oldWidget.pickFile != widget.pickFile) {
      _inspection?.cancel();
    }
  }

  Future<void> _inspect(
    Future<_ImportInspection?> Function(RequestScope scope) action,
  ) async {
    if (_busy || !acceptsSettingsChanges || _installing) return;
    _inspection?.cancel();
    final task = SourceInspectionTask<void>(context);
    _inspection = task;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await task.run((scope) async {
        final result = await action(scope);
        if (result == null) return;
        final selection = result.selection;
        var adopted = identical(selection, _selectionOwner?.selection);
        Object? cause;
        StackTrace? causeStack;
        try {
          if (!mounted || !identical(_inspection, task) || !task.active) return;
          setState(() {
            if (!adopted) {
              _selectionOwner?.release();
              _selectionOwner = selection == null
                  ? null
                  : SourceSelectionOwner(context, selection);
              adopted = true;
            }
            _contents = result.contents;
            _fileName = result.fileName;
            _readFile = result.readFile;
            _showPreview(
              result.preview ??
                  SourceImportPreview.parse(
                    result.contents!,
                    fileName: result.fileName,
                    baseUrl: result.baseUrl,
                  ),
            );
          });
        } catch (error, stack) {
          cause = error;
          causeStack = stack;
          // Relative catalogs keep their selected bytes for base URL correction.
          if (error is! SourceImportNeedsBaseUrl &&
              identical(selection, _selectionOwner?.selection)) {
            _selectionOwner?.release(cause: error, stackTrace: stack);
            _selectionOwner = null;
            _readFile = null;
          }
          rethrow;
        } finally {
          if (!adopted && selection != null) {
            await withSelectedFile<void>(selection, (_) async {
              if (cause != null) Error.throwWithStackTrace(cause, causeStack!);
            });
          }
        }
      });
    } catch (error, stack) {
      if (!mounted || !identical(_inspection, task) || !task.active) {
        Log.info('Retired source preview', '$error\n$stack');
        return;
      }
      setState(() {
        _needsBase = _needsBase || error is SourceImportNeedsBaseUrl;
        _error = sourceFailureMessage(error);
      });
    } finally {
      if (mounted && identical(_inspection, task)) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _identify() {
    final input = _input.text.trim();
    final contents = _contents;
    final fileName = _fileName;
    final readFile = _readFile;
    final selection = _selectionOwner?.selection;
    final baseUrl = _baseUrl.text.trim();
    final createClient = widget.createClient;
    return _inspect((scope) async {
      if (contents == null &&
          RegExp(r'^https?://', caseSensitive: false).hasMatch(input)) {
        return _ImportInspection(
          preview: await SourceImportPreview.fromUrl(
            input,
            createClient: createClient,
            cancelToken: scope.cancelToken,
          ),
        );
      }
      return _ImportInspection(
        contents: contents ?? input,
        fileName: fileName,
        readFile: readFile,
        selection: selection,
        baseUrl: baseUrl.isEmpty ? null : baseUrl,
      );
    });
  }

  Future<void> _chooseFile() {
    final pickFile = widget.pickFile;
    final baseUrl = _baseUrl.text.trim();
    return _inspect((scope) async {
      final file = await (pickFile == null
          ? selectFile(ext: ['js', 'json'], checkStop: scope.check)
          : pickFile());
      if (file == null) return null;
      try {
        scope.check();
        final contents = utf8.decode(await file.readAsBytes());
        return _ImportInspection(
          contents: contents,
          fileName: file.name,
          readFile: file.readAsBytes,
          selection: file,
          baseUrl: baseUrl.isEmpty ? null : baseUrl,
        );
      } catch (error, stack) {
        return withSelectedFile<_ImportInspection?>(file, (_) async {
          Error.throwWithStackTrace(error, stack);
        });
      }
    });
  }

  Future<void> _install() async {
    if (!acceptsSettingsChanges || _installing) return;
    final preview = _preview!;
    final selected = Set<String>.of(_selected);
    final readFile = _readFile;
    final saveRepository = _saveRepository;
    final repositoryName = _repositoryName.text;
    final queue = SourceInstallationsScope.of(context);
    final route = ModalRoute.of(context);
    SourceRepositorySave? request;
    SourceRepository? repository;
    final dispatched = <String>{};
    await saveSetting(
      'import-repository',
      () async {
        _error = null;
        if (preview.catalog == null || !saveRepository || preview.url == null) {
          return;
        }
        try {
          if (request == null) {
            final existing = SourceRepositories.instance.all
                .where((r) => r.url == preview.url)
                .firstOrNull;
            request = SourceRepositories.instance.prepareSave(
              id: existing?.id,
              name: existing?.name ?? repositoryName,
              url: preview.url!,
              catalogContents: preview.contents,
            );
          }
          repository = await request!.save();
        } on SourceFailure catch (failure) {
          _error = sourceFailureMessage(failure);
        } catch (failure) {
          _error = sourceFailureMessage(failure);
          rethrow;
        }
      },
      onSaved: () {
        if (_error != null ||
            !acceptsSettingsChanges ||
            route?.isCurrent != true ||
            !NavigationAdmission.allows(context)) {
          return;
        }
        if (preview.catalog == null) {
          if (!dispatched.contains('script')) {
            final owner = _selectionOwner;
            if (owner == null) {
              queue.enqueuePreviewedScript(
                name: preview.name,
                contents: preview.contents,
                url: preview.url,
                readFile: readFile,
              );
            } else {
              owner.transfer((selection) {
                final task = queue.enqueuePreviewedScript(
                  name: preview.name,
                  contents: preview.contents,
                  url: preview.url,
                  selection: selection,
                );
                return identical(task.selection, selection);
              });
            }
            dispatched.add('script');
          }
        } else {
          for (final entry in preview.catalog!.entries) {
            if (!selected.contains(entry.key) ||
                queue.manager.find(entry.key) != null ||
                dispatched.contains(entry.key)) {
              continue;
            }
            if (repository == null) {
              queue.enqueueCatalogEntry(entry);
            } else {
              queue.enqueueRepository(repository!, entry);
            }
            dispatched.add(entry.key);
          }
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(leaveSettings());
        });
      },
    );
  }

  void _reset() => setState(() {
    _inspection?.cancel();
    _inspection = null;
    _selectionOwner?.release();
    _selectionOwner = null;
    _busy = false;
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
    return protectSettings(
      AlertDialog(
        scrollable: true,
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
                                              SourceInstallationsScope.of(
                                                context,
                                              ).manager.find(e.key) ==
                                              null,
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
                            SourceInstallationsScope.of(
                                      context,
                                    ).manager.find(entry.key) !=
                                    null
                                ? 'Installed'.tl
                                : '${entry.key} · ${entry.version}',
                          ),
                          value: _selected.contains(entry.key),
                          onChanged:
                              _installing ||
                                  SourceInstallationsScope.of(
                                        context,
                                      ).manager.find(entry.key) !=
                                      null
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
                  settingsSaveStatus,
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
                  if (_busy || savingSettings) const LinearProgressIndicator(),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: acceptsSettingsChanges ? leaveSettings : null,
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

class _ImportInspection {
  const _ImportInspection({
    this.preview,
    this.contents,
    this.fileName,
    this.baseUrl,
    this.readFile,
    this.selection,
  });
  final FileSelection? selection;
  final SourceImportPreview? preview;
  final String? contents, fileName, baseUrl;
  final Future<Uint8List> Function()? readFile;
}
