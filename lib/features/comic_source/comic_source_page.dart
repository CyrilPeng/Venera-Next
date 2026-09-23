import 'dart:convert';
import 'dart:io' as io;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/scroll.dart';
import 'package:venera_next/components/select.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/comic_source/comic_source_manager.dart';
import 'package:venera_next/features/comic_source/source.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/app_dio.dart';
import 'package:venera_next/network/cookie_jar.dart';
import 'package:venera_next/routing/webview.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

import 'parser.dart' show compareSemVer;
import 'source_installation.dart';
import 'source_installation_widgets.dart';
import 'source_translation.dart';
import 'source_repositories.dart';
import 'source_repository_page.dart';
import 'source_script_editor.dart';

class ComicSourcePage extends StatelessWidget {
  const ComicSourcePage({super.key});

  @visibleForTesting
  static Dio Function()? debugCreateDio;

  static Dio _createDio() => debugCreateDio?.call() ?? AppDio();

  static final _updating = <String, CancelToken>{};
  static Future<int>? _checking;
  static SourceUpdateCheck? lastUpdateCheck;

  static Future<void> update(
    ComicSource source, [
    bool showLoading = true,
  ]) async {
    if (_updating.containsKey(source.key)) {
      // An interactive duplicate tap stays silent because the loading dialog
      // already owns the update. A batch caller must not mistake the skipped
      // update for a success.
      if (!showLoading) throw 'Update already in progress'.tl;
      return;
    }
    final token = CancelToken();
    _updating[source.key] = token;
    Dio? dio;
    LoadingDialogController? controller;
    final loadingContext = showLoading ? App.rootContext : null;
    void releaseUpdate() {
      if (identical(_updating[source.key], token)) {
        _updating.remove(source.key);
      }
    }

    try {
      if (loadingContext != null) {
        controller = showLoadingDialog(
          loadingContext,
          onCancel: () {
            token.cancel();
            releaseUpdate();
          },
          barrierDismissible: false,
        );
      }
      dio = _createDio();
      final store = SourceRepositories.instance;
      final origin = store.originFor(source.key);
      final repository = store.find(origin?.repositoryId);
      final url = await store.updateUrl(
        source,
        client: dio,
        cancelToken: token,
      );
      if (token.isCancelled) return;
      final res = await dio.get<String>(
        url,
        cancelToken: token,
        options: Options(
          responseType: ResponseType.plain,
          headers: {'cache-time': 'no'},
        ),
      );
      if (token.isCancelled) return;
      await ComicSourceManager().replaceScript(
        source,
        res.data!,
        validate: () {
          if (token.isCancelled) throw token.cancelError!;
          if (store.originFor(source.key)?.repositoryId !=
                  origin?.repositoryId ||
              store.originFor(source.key)?.url != origin?.url ||
              ComicSource.find(source.key)?.filePath != source.filePath ||
              (repository != null &&
                  store.find(repository.id)?.url != repository.url)) {
            throw 'Repository changed. Refresh the list and try again.'.tl;
          }
          // Once the serialized commit begins, the script must be replaced
          // atomically. Cancellation is available while downloading or queued.
          if (loadingContext?.mounted ?? false) controller?.close();
        },
        origin: repository == null
            ? null
            : SourceOrigin(
                kind: 'repository',
                repositoryId: repository.id,
                repositoryName: repository.name,
                url: url,
              ),
      );
    } catch (e, stack) {
      if (!token.isCancelled) {
        Log.error('Update comic source', '$e\n$stack');
        if (showLoading) {
          final context = App.rootNavigatorKey.currentContext;
          if (context != null && context.mounted) {
            context.showMessage(
              message: e is DioException ? 'Network error'.tl : e.toString(),
            );
          }
        } else {
          rethrow;
        }
      }
    } finally {
      if (loadingContext?.mounted ?? false) controller?.close();
      dio?.close();
      releaseUpdate();
    }
  }

  static Future<int> checkComicSourceUpdate() {
    return _checking ??= _checkUpdates().whenComplete(() => _checking = null);
  }

  static Future<int> _checkUpdates() async {
    ComicSourceManager().updateAvailableUpdates({});
    final revision = SourceRepositories.instance.revision;
    var result = await SourceRepositories.instance.checkUpdates(
      ComicSource.all().where((source) => source.filePath.isNotEmpty).toList(),
    );
    if (revision != SourceRepositories.instance.revision) {
      result = SourceUpdateCheck(
        updates: {},
        failures: ['Repository changed. Refresh the list and try again.'.tl],
        checked: 0,
        skipped: ComicSource.all().length,
      );
    }
    lastUpdateCheck = result;
    ComicSourceManager().updateAvailableUpdates(result.updates);
    return result.updates.isEmpty && result.failures.isNotEmpty
        ? -1
        : result.updates.length;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: const _Body());
  }
}

class _Body extends StatefulWidget {
  const _Body();

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> with SingleTickerProviderStateMixin {
  late final tabs = TabController(length: 2, vsync: this);

  void updateUI() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    ComicSourceManager().addListener(updateUI);
  }

  @override
  void dispose() {
    ComicSourceManager().removeListener(updateUI);
    tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Appbar(title: Text('Comic Source'.tl)),
        AppTabBar(
          controller: tabs,
          tabs: [
            Tab(text: 'Installed'.tl),
            Tab(text: 'Source repositories'.tl),
          ],
        ),
        const SourceInstallationSummary(),
        Expanded(
          child: TabBarView(
            controller: tabs,
            children: [
              SmoothCustomScrollView(
                slivers: [
                  buildCard(context),
                  if (ComicSource.isEmpty)
                    SliverToBoxAdapter(
                      child: SourceManagementEmptyState(
                        icon: Icons.extension_outlined,
                        title: 'No installed sources'.tl,
                        description:
                            'Open the Repositories tab to browse and install sources.'
                                .tl,
                      ),
                    ),
                  for (var source in ComicSource.all())
                    _SliverComicSource(
                      key: ValueKey(source.key),
                      source: source,
                      edit: edit,
                      update: update,
                      delete: delete,
                    ),
                  SliverPadding(
                    padding: EdgeInsets.only(bottom: context.padding.bottom),
                  ),
                ],
              ),
              const SourceRepositoriesPanel(),
            ],
          ),
        ),
      ],
    );
  }

  void delete(ComicSource source) {
    showConfirmDialog(
      context: App.rootContext,
      title: 'Uninstall source'.tl,
      content: "Delete comic source '@n' ?".tlParams({"n": source.name}),
      btnColor: context.colorScheme.error,
      onConfirm: () async {
        await ComicSourceManager().uninstallScript(source);
        _validatePages();
        App.forceRebuild();
      },
    );
  }

  void edit(ComicSource source) async {
    if (App.isDesktop) {
      try {
        final directory = Directory('${App.cachePath}/source_edit');
        await directory.create(recursive: true);
        final draft = await File(
          source.filePath,
        ).copy('${directory.path}/${source.key}.js');
        final process = await Process.run("code", [
          draft.path,
        ], runInShell: true);
        if (process.exitCode != 0) throw process.stderr.toString();
        if (!mounted) return;
        String? error;
        bool saving = false;
        await showDialog(
          context: App.rootContext,
          builder: (context) => StatefulBuilder(
            builder: (context, updateDialog) => AlertDialog(
              title: Text("Reload Configs".tl),
              scrollable: true,
              content: SelectableText(
                error ??
                    'Save the file in your editor, then reload it here.'.tl,
              ),
              actions: [
                TextButton(
                  onPressed: saving ? null : () => Navigator.pop(context),
                  child: Text("Cancel".tl),
                ),
                TextButton(
                  onPressed: saving
                      ? null
                      : () async {
                          updateDialog(() {
                            saving = true;
                            error = null;
                          });
                          try {
                            await ComicSourceManager().replaceScript(
                              source,
                              await draft.readAsString(),
                              validate: () {},
                            );
                            if (context.mounted) {
                              updateDialog(() => error = 'Source reloaded'.tl);
                            }
                          } catch (e) {
                            if (context.mounted) {
                              updateDialog(() => error = e.toString());
                            }
                          } finally {
                            if (context.mounted) {
                              updateDialog(() => saving = false);
                            }
                          }
                        },
                  child: Text(saving ? 'Loading'.tl : 'Reload'.tl),
                ),
              ],
            ),
          ),
        );
        return;
      } catch (e) {
        //
      }
    }
    if (!mounted) return;
    try {
      final script = await File(source.filePath).readAsString();
      if (!mounted) return;
      context.to(
        () => SourceScriptEditor(
          script: script,
          onSave: (script) => ComicSourceManager().replaceScript(
            source,
            script,
            validate: () {},
          ),
        ),
      );
    } catch (error) {
      if (mounted) context.showMessage(message: error.toString());
    }
  }

  void update(ComicSource source, [bool showLoading = true]) {
    ComicSourcePage.update(source, showLoading);
  }

  Widget buildCard(BuildContext context) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              const _CheckUpdatesButton(),
              FilledButton.tonalIcon(
                onPressed: _installFromLink,
                icon: const Icon(Icons.link),
                label: Text('Install from link'.tl),
              ),
              FilledButton.tonalIcon(
                onPressed: _selectFile,
                icon: const Icon(Icons.file_open_outlined),
                label: Text('Import source file'.tl),
              ),
              IconButton(
                onPressed: help,
                tooltip: 'Help'.tl,
                icon: const Icon(Icons.help_outline),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Update checks use each source’s linked repository. Link older or manually imported sources to include them.'
                .tl,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );

  Future<void> _installFromLink() async {
    final url = await showDialog<String>(
      context: context,
      builder: (_) => const _SourceUrlDialog(),
    );
    if (url != null) SourceInstallations.instance.enqueueUrl(url);
  }

  void _selectFile() async {
    final file = await selectFile(ext: ["js"]);
    if (file == null) return;
    try {
      final bytes = await file.readAsBytes();
      SourceInstallations.instance.enqueueFile(
        file.name,
        bytes,
        readFile: file.readAsBytes,
      );
    } catch (e, s) {
      App.rootContext.showMessage(message: e.toString());
      Log.error("Add comic source", "$e\n$s");
    }
  }

  void help() {
    launchUrlString(
      "https://github.com/CyrilPeng/venera-next/blob/main/doc/development/source_debugging.zh.md",
    );
  }
}

class _SourceUrlDialog extends StatefulWidget {
  const _SourceUrlDialog();
  @override
  State<_SourceUrlDialog> createState() => _SourceUrlDialogState();
}

class _SourceUrlDialogState extends State<_SourceUrlDialog> {
  final controller = TextEditingController();
  String? error;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void submit() {
    try {
      Navigator.pop(context, SourceRepositories.normalizeUrl(controller.text));
    } catch (e) {
      setState(() => error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Install from link'.tl),
    content: SizedBox(
      width: 440,
      child: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.url,
        autocorrect: false,
        onSubmitted: (_) => submit(),
        decoration: InputDecoration(
          labelText: 'Source script URL'.tl,
          hintText: 'https://example.com/source.js',
          helperText: 'To add a source list, use the Repositories tab.'.tl,
          helperMaxLines: 3,
          errorText: error,
          errorMaxLines: 3,
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text('Cancel'.tl),
      ),
      FilledButton(onPressed: submit, child: Text('Install source'.tl)),
    ],
  );
}

void _validatePages() {
  List explorePages = appdata.settings['explore_pages'];
  List categoryPages = appdata.settings['categories'];
  List networkFavorites = appdata.settings['favorites'];

  var totalExplorePages = ComicSource.all()
      .map((e) => e.explorePages.map((e) => e.title))
      .expand((element) => element)
      .toList();
  var totalCategoryPages = ComicSource.all()
      .map((e) => e.categoryData?.key)
      .where((element) => element != null)
      .map((e) => e!)
      .toList();
  var totalNetworkFavorites = ComicSource.all()
      .map((e) => e.favoriteData?.key)
      .where((element) => element != null)
      .map((e) => e!)
      .toList();

  for (var page in List.from(explorePages)) {
    if (!totalExplorePages.contains(page)) {
      explorePages.remove(page);
    }
  }
  for (var page in List.from(categoryPages)) {
    if (!totalCategoryPages.contains(page)) {
      categoryPages.remove(page);
    }
  }
  for (var page in List.from(networkFavorites)) {
    if (!totalNetworkFavorites.contains(page)) {
      networkFavorites.remove(page);
    }
  }

  appdata.settings['explore_pages'] = explorePages.toSet().toList();
  appdata.settings['categories'] = categoryPages.toSet().toList();
  appdata.settings['favorites'] = networkFavorites.toSet().toList();

  appdata.saveData();
}

class _CheckUpdatesButton extends StatefulWidget {
  const _CheckUpdatesButton();

  @override
  State<_CheckUpdatesButton> createState() => _CheckUpdatesButtonState();
}

class _CheckUpdatesButtonState extends State<_CheckUpdatesButton> {
  bool isLoading = false;

  Future<void> check() async {
    if (isLoading) return;
    setState(() => isLoading = true);
    try {
      await ComicSourcePage.checkComicSourceUpdate();
      if (!mounted) return;
      final result = ComicSourcePage.lastUpdateCheck!;
      if (result.updates.isEmpty &&
          result.failures.isEmpty &&
          result.skipped == 0) {
        context.showMessage(message: 'No updates'.tl);
      } else {
        await showUpdateDialog(result);
      }
    } catch (error) {
      if (mounted) context.showMessage(message: error.toString());
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> showUpdateDialog(SourceUpdateCheck result) async {
    final doUpdate = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Source update check'.tl),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '@checked checked · @skipped not checked'.tlParams({
                    'checked': result.checked.toString(),
                    'skipped': result.skipped.toString(),
                  }),
                ),
                if (result.skipped > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      'Unlinked sources are not checked. Link a repository from each source’s origin menu.'
                          .tl,
                    ),
                  ),
                if (result.updates.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      result.updates.entries
                          .map(
                            (e) =>
                                '${ComicSource.find(e.key)?.name ?? e.key}: ${e.value}',
                          )
                          .join('\n'),
                    ),
                  ),
                if (result.updates.isEmpty && result.checked > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text('Checked sources are up to date.'.tl),
                  ),
                if (result.failures.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      '${'Some sources could not be checked.'.tl}\n${result.failures.join('\n')}',
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
            onPressed: () => Navigator.pop(context, false),
            child: Text('Close'.tl),
          ),
          if (result.updates.isNotEmpty)
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('Update'.tl),
            ),
        ],
      ),
    );
    if (doUpdate != true || !mounted) return;
    final loadingController = showLoadingDialog(
      context,
      message: 'Updating'.tl,
      withProgress: true,
    );
    final failures = <String>[];
    var current = 0;
    try {
      for (final key in result.updates.keys) {
        final source = ComicSource.find(key);
        if (source != null) {
          try {
            await ComicSourcePage.update(source, false);
          } catch (error) {
            failures.add('${source.name}: $error');
          }
        }
        loadingController.setProgress(++current / result.updates.length);
      }
    } finally {
      loadingController.close();
    }
    if (failures.isNotEmpty && mounted) {
      context.showMessage(message: failures.join('\n'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      icon: isLoading
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(Icons.update),
      label: Text("Check updates".tl),
      onPressed: isLoading ? null : check,
    );
  }
}

class _CallbackSetting extends StatefulWidget {
  const _CallbackSetting({required this.setting, required this.sourceKey});

  final MapEntry<String, Map<String, dynamic>> setting;

  final String sourceKey;

  @override
  State<_CallbackSetting> createState() => _CallbackSettingState();
}

class _CallbackSettingState extends State<_CallbackSetting> {
  String get key => widget.setting.key;

  String get buttonText => widget.setting.value['buttonText'] ?? "Click";

  String get title => widget.setting.value['title'] ?? key;

  bool isLoading = false;

  Future<void> onClick() async {
    var func = widget.setting.value['callback'];
    var result = func([]);
    if (result is Future) {
      setState(() {
        isLoading = true;
      });
      try {
        await result;
      } finally {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title.ts(widget.sourceKey)),
      trailing: Button.normal(
        onPressed: onClick,
        isLoading: isLoading,
        child: Text(buttonText.ts(widget.sourceKey)),
      ).fixHeight(32),
    );
  }
}

class _SliverComicSource extends StatefulWidget {
  const _SliverComicSource({
    super.key,
    required this.source,
    required this.edit,
    required this.update,
    required this.delete,
  });

  final ComicSource source;

  final void Function(ComicSource source) edit;
  final void Function(ComicSource source) update;
  final void Function(ComicSource source) delete;

  @override
  State<_SliverComicSource> createState() => _SliverComicSourceState();
}

class _SliverComicSourceState extends State<_SliverComicSource> {
  ComicSource get source => widget.source;

  bool expanded = false;

  @override
  Widget build(BuildContext context) {
    final newVersion = ComicSourceManager().availableUpdates[source.key];
    final hasUpdate =
        newVersion != null && compareSemVer(newVersion, source.version);
    final canManageScript = source.filePath.isNotEmpty;
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(source.name, style: ts.s18),
                          Text(
                            source.version,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          if (hasUpdate)
                            Text(
                              'New Version'.tl,
                              style: TextStyle(
                                color: context.colorScheme.primary,
                              ),
                            ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => setState(() => expanded = !expanded),
                      tooltip:
                          (expanded
                                  ? 'Hide source settings'
                                  : 'Show source settings')
                              .tl,
                      icon: Icon(
                        expanded ? Icons.expand_less : Icons.expand_more,
                      ),
                    ),
                    if (canManageScript)
                      PopupMenuButton<String>(
                        tooltip: 'Source actions'.tl,
                        onSelected: (action) {
                          switch (action) {
                            case 'origin':
                              showSourceOriginPicker(context, source);
                            case 'edit':
                              widget.edit(source);
                            case 'update':
                              widget.update(source);
                            case 'delete':
                              widget.delete(source);
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'origin',
                            child: Text('Manage source origin'.tl),
                          ),
                          PopupMenuItem(
                            value: 'update',
                            child: Text('Update'.tl),
                          ),
                          PopupMenuItem(
                            value: 'edit',
                            child: Text('Edit script'.tl),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: Text('Uninstall source'.tl),
                          ),
                        ],
                      ),
                  ],
                ),
                if (canManageScript)
                  TextButton.icon(
                    onPressed: () => showSourceOriginPicker(context, source),
                    icon: const Icon(Icons.link, size: 16),
                    label: Text(
                      SourceRepositories.instance.originLabel(source.key),
                      textAlign: TextAlign.start,
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (expanded) ...[
          SliverToBoxAdapter(
            child: Column(children: buildSourceSettings().toList()),
          ),
          SliverToBoxAdapter(child: Column(children: _buildAccount().toList())),
        ],
        const SliverToBoxAdapter(child: Divider(indent: 16, endIndent: 16)),
      ],
    );
  }

  Iterable<Widget> buildSourceSettings() sync* {
    // Try to get dynamic settings first (for getters), fall back to cached settings
    var settingsMap = source.getSettingsDynamic() ?? source.settings;

    if (settingsMap == null) {
      return;
    } else if (source.data['settings'] == null) {
      source.data['settings'] = {};
    }
    for (var item in settingsMap.entries) {
      var key = item.key;
      String type = item.value['type'];
      try {
        if (type == "select") {
          var current = source.data['settings'][key];
          if (current == null) {
            var d = item.value['default'];
            for (var option in item.value['options']) {
              if (option['value'] == d) {
                current = option['text'] ?? option['value'];
                break;
              }
            }
          } else {
            current =
                item.value['options'].firstWhere(
                  (e) => e['value'] == current,
                )['text'] ??
                current;
          }
          yield ListTile(
            title: Text((item.value['title'] as String).ts(source.key)),
            trailing: Select(
              current: (current as String).ts(source.key),
              values: (item.value['options'] as List)
                  .map<String>(
                    (e) => ((e['text'] ?? e['value']) as String).ts(source.key),
                  )
                  .toList(),
              onTap: (i) {
                source.data['settings'][key] =
                    item.value['options'][i]['value'];
                source.saveData();
                setState(() {});
              },
            ),
          );
        } else if (type == "switch") {
          var current = source.data['settings'][key] ?? item.value['default'];
          yield ListTile(
            title: Text((item.value['title'] as String).ts(source.key)),
            trailing: Switch(
              value: current,
              onChanged: (v) {
                source.data['settings'][key] = v;
                source.saveData();
                setState(() {});
              },
            ),
          );
        } else if (type == "input") {
          var current =
              source.data['settings'][key] ?? item.value['default'] ?? '';
          yield ListTile(
            title: Text((item.value['title'] as String).ts(source.key)),
            subtitle: Text(
              current,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              icon: const Icon(Icons.edit),
              onPressed: () {
                showInputDialog(
                  context: context,
                  title: (item.value['title'] as String).ts(source.key),
                  initialValue: current,
                  inputValidator: item.value['validator'] == null
                      ? null
                      : RegExp(item.value['validator']),
                  onConfirm: (value) {
                    source.data['settings'][key] = value;
                    source.saveData();
                    setState(() {});
                    return null;
                  },
                );
              },
            ),
          );
        } else if (type == "callback") {
          yield _CallbackSetting(setting: item, sourceKey: source.key);
        }
      } catch (e, s) {
        Log.error("ComicSourcePage", "Failed to build a setting\n$e\n$s");
      }
    }
  }

  final _reLogin = <String, bool>{};

  Iterable<Widget> _buildAccount() sync* {
    if (source.account == null) return;
    final bool logged = source.isLogged;
    if (!logged) {
      yield ListTile(
        title: Text("Log in".tl),
        trailing: const Icon(Icons.arrow_right),
        onTap: () async {
          await context.to(
            () => _LoginPage(config: source.account!, source: source),
          );
          source.saveData();
          setState(() {});
        },
      );
    }
    if (logged) {
      for (var item in source.account!.infoItems) {
        if (item.builder != null) {
          yield item.builder!(context);
        } else {
          yield ListTile(
            title: Text(item.title.tl),
            subtitle: item.data == null ? null : Text(item.data!()),
            onTap: item.onTap,
          );
        }
      }
      if (source.data["account"] is List) {
        bool loading = _reLogin[source.key] == true;
        yield ListTile(
          title: Text("Re-login".tl),
          subtitle: Text("Click if login expired".tl),
          onTap: () async {
            if (source.data["account"] == null) {
              context.showMessage(message: "No data".tl);
              return;
            }
            setState(() {
              _reLogin[source.key] = true;
            });
            final List account = source.data["account"];
            var res = await source.account!.login!(account[0], account[1]);
            if (res.error) {
              context.showMessage(message: res.errorMessage!);
            } else {
              context.showMessage(message: "Success".tl);
            }
            setState(() {
              _reLogin[source.key] = false;
            });
          },
          trailing: loading
              ? const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
        );
      }
      yield ListTile(
        title: Text("Log out".tl),
        onTap: () {
          source.data["account"] = null;
          source.account?.logout();
          source.saveData();
          ComicSourceManager().notifyStateChange();
          setState(() {});
        },
        trailing: const Icon(Icons.logout),
      );
    }
  }
}

class _LoginPage extends StatefulWidget {
  const _LoginPage({required this.config, required this.source});

  final AccountConfig config;

  final ComicSource source;

  @override
  State<_LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<_LoginPage> {
  String username = "";
  String password = "";
  bool loading = false;

  final Map<String, String> _cookies = {};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const Appbar(title: Text('')),
      body: Center(
        child: Container(
          padding: const EdgeInsets.all(16),
          constraints: const BoxConstraints(maxWidth: 400),
          child: AutofillGroup(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("Login".tl, style: const TextStyle(fontSize: 24)),
                const SizedBox(height: 32),
                if (widget.config.cookieFields == null)
                  TextField(
                    decoration: InputDecoration(
                      labelText: "Username".tl,
                      border: const OutlineInputBorder(),
                    ),
                    enabled: widget.config.login != null,
                    onChanged: (s) {
                      username = s;
                    },
                    autofillHints: const [AutofillHints.username],
                  ).paddingBottom(16),
                if (widget.config.cookieFields == null)
                  TextField(
                    decoration: InputDecoration(
                      labelText: "Password".tl,
                      border: const OutlineInputBorder(),
                    ),
                    obscureText: true,
                    enabled: widget.config.login != null,
                    onChanged: (s) {
                      password = s;
                    },
                    onSubmitted: (s) => login(),
                    autofillHints: const [AutofillHints.password],
                  ).paddingBottom(16),
                for (var field in widget.config.cookieFields ?? <String>[])
                  TextField(
                    decoration: InputDecoration(
                      labelText: field,
                      border: const OutlineInputBorder(),
                    ),
                    obscureText: true,
                    enabled: widget.config.validateCookies != null,
                    onChanged: (s) {
                      _cookies[field] = s;
                    },
                  ).paddingBottom(16),
                if (widget.config.login == null &&
                    widget.config.cookieFields == null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline),
                      const SizedBox(width: 8),
                      Text("Login with password is disabled".tl),
                    ],
                  )
                else
                  Button.filled(
                    isLoading: loading,
                    onPressed: login,
                    child: Text("Continue".tl),
                  ),
                const SizedBox(height: 24),
                if (widget.config.loginWebsite != null)
                  TextButton(
                    onPressed: () {
                      if (App.isLinux) {
                        loginWithWebview2();
                      } else {
                        loginWithWebview();
                      }
                    },
                    child: Text("Login with webview".tl),
                  ),
                const SizedBox(height: 8),
                if (widget.config.registerWebsite != null)
                  TextButton(
                    onPressed: () =>
                        launchUrlString(widget.config.registerWebsite!),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.link),
                        const SizedBox(width: 8),
                        Text("Create Account".tl),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void login() {
    if (widget.config.login != null) {
      if (username.isEmpty || password.isEmpty) {
        showToast(
          message: "Cannot be empty".tl,
          icon: const Icon(Icons.error_outline),
          context: context,
        );
        return;
      }
      setState(() {
        loading = true;
      });
      widget.config.login!(username, password).then((value) {
        if (value.error) {
          context.showMessage(message: value.errorMessage!);
          setState(() {
            loading = false;
          });
        } else {
          if (mounted) {
            context.pop();
          }
        }
      });
    } else if (widget.config.validateCookies != null) {
      setState(() {
        loading = true;
      });
      var cookies = widget.config.cookieFields!
          .map((e) => _cookies[e] ?? '')
          .toList();
      widget.config.validateCookies!(cookies).then((value) {
        if (value) {
          widget.source.data['account'] = 'ok';
          widget.source.saveData();
          context.pop();
        } else {
          context.showMessage(message: "Invalid cookies".tl);
          setState(() {
            loading = false;
          });
        }
      });
    }
  }

  void loginWithWebview() async {
    var url = widget.config.loginWebsite!;
    var title = '';
    bool success = false;

    void validate(InAppWebViewController c) async {
      if (widget.config.checkLoginStatus != null &&
          widget.config.checkLoginStatus!(url, title)) {
        var cookies = (await c.getCookies(url)) ?? [];
        var localStorageItems = await c.webStorage.localStorage.getItems();
        var mappedLocalStorage = <String, dynamic>{};
        for (var item in localStorageItems) {
          if (item.key != null) {
            mappedLocalStorage[item.key!] = item.value;
          }
        }
        widget.source.data['_localStorage'] = mappedLocalStorage;
        await widget.source.saveData();
        SingleInstanceCookieJar.instance?.saveFromResponse(
          Uri.parse(url),
          cookies,
        );
        success = true;
        widget.config.onLoginWithWebviewSuccess?.call();
        App.mainNavigatorKey?.currentContext?.pop();
      }
    }

    await context.to(
      () => AppWebview(
        initialUrl: widget.config.loginWebsite!,
        onNavigation: (u, c) {
          url = u;
          validate(c);
          return false;
        },
        onTitleChange: (t, c) {
          title = t;
          validate(c);
        },
      ),
    );
    if (success) {
      widget.source.data['account'] = 'ok';
      widget.source.saveData();
      context.pop();
    }
  }

  // for linux
  void loginWithWebview2() async {
    if (!await DesktopWebview.isAvailable()) {
      context.showMessage(message: "Webview is not available".tl);
    }

    var url = widget.config.loginWebsite!;
    var title = '';
    bool success = false;

    void onClose() {
      if (success) {
        widget.source.data['account'] = 'ok';
        widget.source.saveData();
        context.pop();
      }
    }

    void validate(DesktopWebview webview) async {
      if (widget.config.checkLoginStatus != null &&
          widget.config.checkLoginStatus!(url, title)) {
        var cookiesMap = await webview.getCookies(url);
        var cookies = <io.Cookie>[];
        cookiesMap.forEach((key, value) {
          cookies.add(io.Cookie(key, value));
        });
        SingleInstanceCookieJar.instance?.saveFromResponse(
          Uri.parse(url),
          cookies,
        );
        var localStorageJson = await webview.evaluateJavascript(
          "JSON.stringify(window.localStorage);",
        );
        var localStorage = <String, dynamic>{};
        try {
          var decoded = jsonDecode(localStorageJson ?? '');
          if (decoded is Map<String, dynamic>) {
            localStorage = decoded;
          }
        } catch (e) {
          Log.error("ComicSourcePage", "Failed to parse localStorage JSON\n$e");
        }
        widget.source.data['_localStorage'] = localStorage;
        await widget.source.saveData();
        success = true;
        widget.config.onLoginWithWebviewSuccess?.call();
        webview.close();
        onClose();
      }
    }

    var webview = DesktopWebview(
      initialUrl: widget.config.loginWebsite!,
      onTitleChange: (t, webview) {
        title = t;
        validate(webview);
      },
      onNavigation: (u, webview) {
        url = u;
        validate(webview);
      },
      onClose: onClose,
    );

    webview.open();
  }
}
