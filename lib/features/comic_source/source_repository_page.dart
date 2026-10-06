import 'dart:async';
import 'source_failure.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'source_failure_presentation.dart';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart' show Dio;
import 'package:venera_next/components/pop_up_widget.dart';
import 'package:venera_next/foundation/translations.dart';

import 'comic_source_manager.dart';
import 'source.dart';
import 'source_repositories.dart';
import 'source_installations_scope.dart';
import 'source_inspection_task.dart';
import 'package:venera_next/foundation/log.dart';
import 'source_installation_widgets.dart';

class SourceRepositoriesPanel extends StatelessWidget {
  const SourceRepositoriesPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final store = SourceRepositories.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([store, ComicSourceManager()]),
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Save repositories to browse and install comic sources.'.tl),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: () => _editRepository(context),
              icon: const Icon(Icons.add),
              label: Text('Add repository'.tl),
            ),
          ),
          const SizedBox(height: 16),
          if (store.all.isEmpty)
            SourceManagementEmptyState(
              icon: Icons.inventory_2_outlined,
              title: 'No repositories yet'.tl,
              description:
                  'Add a repository using its source list URL. Installed sources are managed in the Installed tab.'
                      .tl,
            ),
          for (final repository in store.all)
            Card.outlined(
              margin: const EdgeInsets.only(bottom: 12),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.inventory_2_outlined),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            repository.name,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        PopupMenuButton<String>(
                          tooltip: 'Repository actions'.tl,
                          onSelected: (action) {
                            if (action == 'edit') {
                              _editRepository(context, repository);
                            }
                            if (action == 'remove') {
                              _removeRepository(context, repository);
                            }
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem(
                              value: 'edit',
                              child: Text('Edit repository'.tl),
                            ),
                            PopupMenuItem(
                              value: 'remove',
                              child: Text('Remove repository'.tl),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      repository.url,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 16,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '@count linked sources'.tlParams({
                            'count': _linkedCount(repository).toString(),
                          }),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: () => showPopUpWidget(
                            context,
                            SourceRepositoryCatalogPage(repository: repository),
                          ),
                          icon: const Icon(Icons.library_add_outlined),
                          label: Text('Browse sources'.tl),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  int _linkedCount(SourceRepository repository) => ComicSource.all()
      .where(
        (s) =>
            SourceRepositories.instance.originFor(s.key)?.repositoryId ==
            repository.id,
      )
      .length;

  Future<void> _editRepository(
    BuildContext context, [
    SourceRepository? repository,
  ]) => showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _RepositoryEditor(repository: repository),
  );

  Future<void> _removeRepository(
    BuildContext context,
    SourceRepository repository,
  ) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RepositoryActionDialog(
        title: 'Remove repository'.tl,
        content:
            'Remove "@name"? Its @count linked sources, their settings and your reading data will be kept. These sources will no longer be included in repository update checks.'
                .tlParams({
                  'name': repository.name,
                  'count': _linkedCount(repository).toString(),
                }),
        perform: () => SourceRepositories.instance.remove(repository),
      ),
    );
  }
}

class _RepositoryEditor extends StatefulWidget {
  const _RepositoryEditor({this.repository});
  final SourceRepository? repository;
  @override
  State<_RepositoryEditor> createState() => _RepositoryEditorState();
}

class _RepositoryEditorState extends SettingsSaveState<_RepositoryEditor> {
  late final name = TextEditingController(text: widget.repository?.name);
  late final url = TextEditingController(text: widget.repository?.url);
  bool get saving => savingSettings;
  bool get busy => savingSettings || hasSettingsSaveError;
  String? error;

  @override
  void dispose() {
    name.dispose();
    url.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (!acceptsSettingsChanges || busy) return;
    final id = widget.repository?.id;
    final capturedName = name.text;
    final capturedUrl = url.text;
    SourceRepositorySave? request;
    error = null;
    await saveSetting(
      'repository',
      () async {
        error = null;
        try {
          request ??= SourceRepositories.instance.prepareSave(
            id: id,
            name: capturedName,
            url: capturedUrl,
          );
          await request!.validate();
        } catch (failure) {
          // Validation has not published anything; keep the input editable.
          error = sourceFailureMessage(failure);
          return;
        }
        try {
          await request!.save();
        } on SourceFailure catch (failure) {
          error = sourceFailureMessage(failure);
        } catch (failure) {
          error = sourceFailureMessage(failure);
          rethrow;
        }
      },
      onSaved: () {
        if (error == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(leaveSettings());
          });
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) => protectSettings(
    AlertDialog(
      scrollable: true,
      title: Text(
        (widget.repository == null ? 'Add repository' : 'Edit repository').tl,
      ),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(child: Text('Repository name'.tl)),
            const SizedBox(height: 8),
            Semantics(
              label: 'Repository name'.tl,
              child: TextField(
                controller: name,
                autofocus: true,
                enabled: !busy,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  hintText: 'A name you recognize'.tl,
                ),
              ),
            ),
            const SizedBox(height: 16),
            ExcludeSemantics(child: Text('Source list URL'.tl)),
            const SizedBox(height: 8),
            Semantics(
              label: 'Source list URL'.tl,
              child: TextField(
                controller: url,
                enabled: !busy,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  hintText: 'https://example.com/index.json',
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Use the JSON source list address, not a single script link.'.tl,
            ),
            if (widget.repository != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'Changing this address also changes where linked sources check for updates.'
                      .tl,
                ),
              ),
            settingsSaveStatus,
            if (saving)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: LinearProgressIndicator(
                  semanticsLabel: 'Validating repository'.tl,
                ),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: acceptsSettingsChanges ? leaveSettings : null,
          child: Text('Cancel'.tl),
        ),
        FilledButton(
          onPressed: busy ? null : save,
          child: Text((saving ? 'Validating repository' : 'Save').tl),
        ),
      ],
    ),
  );
}

class _RepositoryActionDialog extends StatefulWidget {
  const _RepositoryActionDialog({
    required this.title,
    required this.content,
    required this.perform,
  });
  final String title;
  final String content;
  final Future<void> Function() perform;
  @override
  State<_RepositoryActionDialog> createState() =>
      _RepositoryActionDialogState();
}

class _RepositoryActionDialogState
    extends SettingsSaveState<_RepositoryActionDialog> {
  String? error;
  Future<void> submit() async {
    if (!acceptsSettingsChanges || savingSettings || hasSettingsSaveError) {
      return;
    }
    final perform = widget.perform;
    await saveSetting(
      'repository-action',
      () async {
        error = null;
        try {
          await perform();
        } on SourceFailure catch (failure) {
          error = sourceFailureMessage(failure);
        } catch (failure) {
          error = sourceFailureMessage(failure);
          rethrow;
        }
      },
      onSaved: () {
        if (error == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(leaveSettings());
          });
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) => protectSettings(
    AlertDialog(
      scrollable: true,
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.content),
          settingsSaveStatus,
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: acceptsSettingsChanges ? leaveSettings : null,
          child: Text('Cancel'.tl),
        ),
        FilledButton(
          onPressed: savingSettings || hasSettingsSaveError ? null : submit,
          child: Text(widget.title),
        ),
      ],
    ),
  );
}

class SourceRepositoryCatalogPage extends StatefulWidget {
  const SourceRepositoryCatalogPage({
    super.key,
    required this.repository,
    this.sourceToLink,
    this.createClient,
  });
  final SourceRepository repository;
  final ComicSource? sourceToLink;
  final Dio Function()? createClient;
  @override
  State<SourceRepositoryCatalogPage> createState() =>
      _SourceRepositoryCatalogPageState();
}

class _SourceRepositoryCatalogPageState
    extends State<SourceRepositoryCatalogPage> {
  List<SourceCatalogEntry>? entries;
  List<String> skipped = const [];
  String? error;
  String query = '';
  bool loading = false;
  SourceInspectionTask<SourceCatalog>? _inspection;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_inspection == null || !_inspection!.sameWindow) load();
  }

  @override
  void didUpdateWidget(covariant SourceRepositoryCatalogPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository ||
        oldWidget.createClient != widget.createClient) {
      load();
    }
  }

  @override
  void dispose() {
    _inspection?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    _inspection?.cancel();
    final task = SourceInspectionTask<SourceCatalog>(context);
    _inspection = task;
    final repository = widget.repository;
    final createClient = widget.createClient;
    bool isCurrent() => mounted && identical(_inspection, task) && task.active;
    setState(() {
      loading = true;
      error = null;
      entries = null;
      skipped = const [];
    });
    try {
      final result = await task.run(
        (scope) => SourceRepositories.instance.load(
          repository,
          createClient: createClient,
          cancelToken: scope.cancelToken,
        ),
      );
      if (isCurrent()) {
        setState(() {
          entries = result.entries;
          skipped = result.skipped;
        });
      }
    } catch (e, stack) {
      if (!isCurrent()) Log.info('Retired source catalog', '$e\n$stack');
      if (isCurrent()) {
        setState(() => error = sourceFailureMessage(e));
      }
    } finally {
      if (mounted && identical(_inspection, task)) {
        setState(() => loading = false);
      }
    }
  }

  Future<void> act(SourceCatalogEntry entry) async {
    final source = SourceInstallationsScope.of(context).manager.find(entry.key);
    if (source != null) {
      final repository = widget.repository;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _RepositoryActionDialog(
          title: 'Link repository'.tl,
          content:
              'Use "@repository" for future updates of "@source"? The installed script and its settings will be kept until you update it.'
                  .tlParams({
                    'repository': repository.name,
                    'source': source.name,
                  }),
          perform: () =>
              SourceRepositories.instance.link(source.key, repository, entry),
        ),
      );
      return;
    }
    setState(() {
      error = null;
    });
    try {
      if (SourceRepositories.instance.find(widget.repository.id)?.url !=
          widget.repository.url) {
        throw 'Repository changed. Refresh the list and try again.'.tl;
      }
      SourceInstallationsScope.of(
        context,
      ).enqueueRepository(widget.repository, entry);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = sourceFailureMessage(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = (entries ?? <SourceCatalogEntry>[])
        .where(
          (entry) =>
              (widget.sourceToLink == null ||
                  entry.key == widget.sourceToLink!.key) &&
              '${entry.name} ${entry.description}'.toLowerCase().contains(
                query.toLowerCase(),
              ),
        )
        .toList();
    return PopUpWidgetScaffold(
      title: 'Browse sources'.tl,
      tailing: const [SourceInstallationSummary(compact: true)],
      body: ListenableBuilder(
        listenable: Listenable.merge([
          SourceRepositories.instance,
          SourceInstallationsScope.of(context).manager,
          SourceInstallationsScope.of(context),
        ]),
        builder: (context, _) => Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    widget.repository.name,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    widget.repository.url,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  if (widget.sourceToLink != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        'Choose the variant to use for "@name".'.tlParams({
                          'name': widget.sourceToLink!.name,
                        }),
                      ),
                    ),
                  TextField(
                    onChanged: (text) => setState(() => query = text),
                    decoration: InputDecoration(
                      labelText: 'Search sources'.tl,
                      prefixIcon: const Icon(Icons.search),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: loading ? null : load,
                      icon: const Icon(Icons.refresh),
                      label: Text('Refresh list'.tl),
                    ),
                  ),
                  if (loading) const LinearProgressIndicator(),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (skipped.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        'Skipped @count invalid source entries: @names'
                            .tlParams({
                              'count': skipped.length.toString(),
                              'names': skipped.join(', '),
                            }),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (!loading && error == null && visible.isEmpty)
                    SourceManagementEmptyState(
                      icon: Icons.search_off,
                      title:
                          (widget.sourceToLink != null
                                  ? 'This source is not listed in this repository.'
                                  : 'No sources found')
                              .tl,
                      description: 'Try another search or refresh the list.'.tl,
                    ),
                  for (final entry in visible) _entry(context, entry),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _entry(BuildContext context, SourceCatalogEntry entry) {
    final installed =
        SourceInstallationsScope.of(context).manager.find(entry.key) != null;
    final matchingTask = SourceInstallationsScope.of(
      context,
    ).taskFor(sourceKey: entry.key, url: entry.url);
    // Share active work across repositories. A past failure belongs only to
    // its original entry, so another repository can start a fresh attempt.
    final task =
        matchingTask != null &&
            (matchingTask.active ||
                (matchingTask.repository?.id == widget.repository.id &&
                    matchingTask.repository?.url == widget.repository.url &&
                    matchingTask.url == entry.url))
        ? matchingTask
        : null;
    final origin = SourceRepositories.instance.originFor(entry.key);
    final linked =
        installed &&
        origin?.repositoryId == widget.repository.id &&
        origin?.url == entry.url;
    return Padding(
      key: ObjectKey(entry),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(entry.name, style: Theme.of(context).textTheme.titleMedium),
          Text(entry.version, style: Theme.of(context).textTheme.bodySmall),
          if (entry.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(entry.description),
            ),
          const SizedBox(height: 8),
          if (task != null && (task.active || (!installed && task.canRetry)))
            SourceInstallationStatus(
              task: task,
              originLabel: task.repository?.id != widget.repository.id
                  ? 'Installation task from @origin'.tlParams({
                      'origin': task.originLabel,
                    })
                  : null,
            )
          else
            SourceInstallationRow(
              text: installed
                  ? 'Installed · @origin'.tlParams({
                      'origin': SourceRepositories.instance.originLabel(
                        entry.key,
                      ),
                    })
                  : '',
              action: linked
                  ? Tooltip(
                      message: 'Linked to this repository'.tl,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.check,
                              size: 18,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                'Installed'.tl,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : Tooltip(
                      message:
                          (installed ? 'Use this repository' : 'Install source')
                              .tl,
                      child: FilledButton.tonal(
                        onPressed: loading ? null : () => act(entry),
                        child: Text(
                          (installed ? 'Use this repository' : 'Install source')
                              .tl,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
            ),
          const SizedBox(height: 8),
          const Divider(),
        ],
      ),
    );
  }
}

Future<void> showSourceOriginPicker(
  BuildContext context,
  ComicSource source,
) async {
  final repository = await showDialog<SourceRepository>(
    context: context,
    builder: (_) => _SourceOriginPicker(source: source),
  );
  if (repository == null || !context.mounted) return;
  await showPopUpWidget(
    context,
    SourceRepositoryCatalogPage(repository: repository, sourceToLink: source),
  );
}

class _SourceOriginPicker extends StatefulWidget {
  const _SourceOriginPicker({required this.source});
  final ComicSource source;
  @override
  State<_SourceOriginPicker> createState() => _SourceOriginPickerState();
}

class _SourceOriginPickerState extends SettingsSaveState<_SourceOriginPicker> {
  final store = SourceRepositories.instance;
  late final origin = store.originFor(widget.source.key);
  String? error;
  bool get busy => savingSettings || hasSettingsSaveError;
  Future<void> unlink() async {
    if (!acceptsSettingsChanges || busy || origin == null) return;
    final key = widget.source.key;
    final original = origin!;
    await saveSetting(
      'origin',
      () async {
        error = null;
        try {
          await store.unlink(key, original);
        } on SourceFailure catch (failure) {
          // A different link superseded this dialog; do not remove it.
          error = sourceFailureMessage(failure);
        } catch (failure) {
          error = sourceFailureMessage(failure);
          rethrow;
        }
      },
      onSaved: () {
        if (error == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(leaveSettings());
          });
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) => protectSettings(
    SimpleDialog(
      title: Text('Manage source origin'.tl),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Text(
            'Current origin: @origin'.tlParams({
              'origin': store.originLabel(widget.source.key),
            }),
          ),
        ),
        settingsSaveStatus,
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (origin?.kind == 'repository')
          SimpleDialogOption(
            onPressed: busy ? null : unlink,
            child: Text('Remove repository link'.tl),
          ),
        if (store.all.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Add a repository in the Repositories tab first.'.tl),
          ),
        for (final repository in store.all)
          SimpleDialogOption(
            onPressed: busy ? null : () => Navigator.pop(context, repository),
            child: ListTile(
              title: Text(repository.name),
              subtitle: Text(
                repository.url,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        TextButton(
          onPressed: acceptsSettingsChanges ? leaveSettings : null,
          child: Text('Cancel'.tl),
        ),
      ],
    ),
  );
}

class SourceManagementEmptyState extends StatelessWidget {
  const SourceManagementEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
  });
  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
    child: Column(
      children: [
        Icon(
          icon,
          size: 40,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(description, textAlign: TextAlign.center),
      ],
    ),
  );
}
