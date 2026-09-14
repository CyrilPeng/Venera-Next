import 'package:flutter/material.dart';
import 'package:venera_next/components/pop_up_widget.dart';
import 'package:venera_next/foundation/translations.dart';

import 'comic_source_manager.dart';
import 'source.dart';
import 'source_repositories.dart';
import 'source_installation.dart';
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove repository'.tl),
        content: Text(
          'Remove "@name"? Its @count linked sources, their settings and your reading data will be kept. These sources will no longer be included in repository update checks.'
              .tlParams({
                'name': repository.name,
                'count': _linkedCount(repository).toString(),
              }),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel'.tl),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Remove repository'.tl),
          ),
        ],
      ),
    );
    if (confirmed == true) await SourceRepositories.instance.remove(repository);
  }
}

class _RepositoryEditor extends StatefulWidget {
  const _RepositoryEditor({this.repository});
  final SourceRepository? repository;
  @override
  State<_RepositoryEditor> createState() => _RepositoryEditorState();
}

class _RepositoryEditorState extends State<_RepositoryEditor> {
  late final name = TextEditingController(text: widget.repository?.name);
  late final url = TextEditingController(text: widget.repository?.url);
  bool saving = false;
  String? error;

  @override
  void dispose() {
    name.dispose();
    url.dispose();
    super.dispose();
  }

  Future<void> save() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await SourceRepositories.instance.save(
        id: widget.repository?.id,
        name: name.text,
        url: url.text,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
          saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: AlertDialog(
      title: Text(
        (widget.repository == null ? 'Add repository' : 'Edit repository').tl,
      ),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                enabled: !saving,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: 'Repository name'.tl,
                  hintText: 'A name you recognize'.tl,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: url,
                enabled: !saving,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: 'Source list URL'.tl,
                  hintText: 'https://example.com/index.json',
                  helperText:
                      'Use the JSON source list address, not a single script link.'
                          .tl,
                  helperMaxLines: 3,
                ),
              ),
              if (widget.repository != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'Changing this address also changes where linked sources check for updates.'
                        .tl,
                  ),
                ),
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
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          child: Text('Cancel'.tl),
        ),
        FilledButton(
          onPressed: saving ? null : save,
          child: Text((saving ? 'Validating repository' : 'Save').tl),
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
  });
  final SourceRepository repository;
  final ComicSource? sourceToLink;
  @override
  State<SourceRepositoryCatalogPage> createState() =>
      _SourceRepositoryCatalogPageState();
}

class _SourceRepositoryCatalogPageState
    extends State<SourceRepositoryCatalogPage> {
  List<SourceCatalogEntry>? entries;
  String? error;
  String query = '';
  bool loading = false;
  final linkingUrls = <String>{};

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
      entries = null;
    });
    try {
      final result = await SourceRepositories.instance.load(widget.repository);
      if (mounted) {
        setState(() {
          entries = result;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          loading = false;
        });
      }
    }
  }

  Future<void> act(SourceCatalogEntry entry) async {
    final source = ComicSource.find(entry.key);
    if (source != null) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Link repository'.tl),
          content: Text(
            'Use "@repository" for future updates of "@source"? The installed script and its settings will be kept until you update it.'
                .tlParams({
                  'repository': widget.repository.name,
                  'source': source.name,
                }),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Cancel'.tl),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('Link repository'.tl),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() {
      if (source != null) linkingUrls.add(entry.url);
      error = null;
    });
    try {
      if (SourceRepositories.instance.find(widget.repository.id)?.url !=
          widget.repository.url) {
        throw 'Repository changed. Refresh the list and try again.'.tl;
      }
      if (source != null) {
        await SourceRepositories.instance.link(
          source.key,
          widget.repository,
          entry,
        );
      } else {
        SourceInstallations.instance.enqueueRepository(
          widget.repository,
          entry,
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          linkingUrls.remove(entry.url);
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
          ComicSourceManager(),
          SourceInstallations.instance,
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
    final installed = ComicSource.find(entry.key) != null;
    final matchingTask = SourceInstallations.instance.taskFor(
      sourceKey: entry.key,
      url: entry.url,
    );
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
                        onPressed: linkingUrls.contains(entry.url) || loading
                            ? null
                            : () => act(entry),
                        child: linkingUrls.contains(entry.url)
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(
                                (installed
                                        ? 'Use this repository'
                                        : 'Install source')
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
  final store = SourceRepositories.instance;
  final repository = await showDialog<SourceRepository>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text('Manage source origin'.tl),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Text(
            'Current origin: @origin'.tlParams({
              'origin': store.originLabel(source.key),
            }),
          ),
        ),
        if (store.all.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Add a repository in the Repositories tab first.'.tl),
          ),
        for (final repository in store.all)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, repository),
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
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel'.tl),
        ),
      ],
    ),
  );
  if (repository == null || !context.mounted) return;
  await showPopUpWidget(
    context,
    SourceRepositoryCatalogPage(repository: repository, sourceToLink: source),
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
