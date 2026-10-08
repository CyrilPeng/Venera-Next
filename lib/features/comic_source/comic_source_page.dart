import 'source_failure_presentation.dart';
import 'dart:async';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'dart:convert';
import 'dart:io' as io;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/scroll.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/features/comic_source/comic_source_manager.dart';
import 'package:venera_next/features/comic_source/source.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/cookie_jar.dart';
import 'package:venera_next/routing/webview.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

import 'parser.dart' show compareSemVer;
import 'source_installation_widgets.dart';
import 'source_installations_scope.dart';
import 'source_translation.dart';
import 'source_repositories.dart';
import 'source_repository_page.dart';
import 'source_script_editor.dart';
import 'source_script_files.dart';
import 'source_script_session.dart';
import 'source_import_dialog.dart';
import 'source_update_service.dart';
import 'source_update_prompt.dart';
import 'source_mutation_failure.dart';

class ComicSourcePage extends StatelessWidget {
  const ComicSourcePage({
    super.key,
    this.scriptFiles = const SourceScriptFiles(),
  });

  final SourceScriptFiles scriptFiles;

  @override
  Widget build(BuildContext context) {
    final owner = SourceInstallationsScope.ownerOf(context);
    return Scaffold(
      body: _Body(
        manager: owner.queue.manager,
        updates: owner.updates,
        refresh: owner.refresh,
        scriptFiles: scriptFiles,
      ),
    );
  }
}

class _Body extends StatefulWidget {
  const _Body({
    required this.manager,
    required this.scriptFiles,
    this.updates,
    this.refresh,
  });

  final ComicSourceManager manager;
  final SourceScriptFiles scriptFiles;
  final SourceUpdateService? updates;
  final VoidCallback? refresh;

  @override
  State<_Body> createState() => _BodyState();
}

AppBar _sourceAppbar(BuildContext context, String title) => AppBar(
  leading: const BackButton(),
  title: Text(
    title,
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
  ),
  titleTextStyle: Theme.of(
    context,
  ).textTheme.titleLarge?.copyWith(fontSize: 20),
  toolbarHeight: (MediaQuery.textScalerOf(context).scale(20) * 1.5 + 16).clamp(
    56,
    double.infinity,
  ),
);

class _BodyState extends State<_Body> with SingleTickerProviderStateMixin {
  late final tabs = TabController(length: 2, vsync: this);
  final _openingEditors = Set<ComicSource>.identity();
  final _updates = Set<SourceUpdatePrompt>.identity();
  final _deletions = Map<ComicSource, WindowSelectionTask>.identity();
  final _deletionFailures = Map<ComicSource, SourceMutationFailure>.identity();

  void _cancelActions() {
    for (final prompt in _updates) {
      prompt.cancel();
    }
    for (final task in _deletions.values) {
      task.cancel();
    }
  }

  void updateUI() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    if (!widget.manager.isClosing) widget.manager.addListener(updateUI);
  }

  @override
  void didUpdateWidget(covariant _Body oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.manager, widget.manager) ||
        !identical(oldWidget.updates, widget.updates)) {
      _cancelActions();
    }
    if (!identical(oldWidget.manager, widget.manager)) {
      oldWidget.manager.removeListener(updateUI);
      if (!widget.manager.isClosing) widget.manager.addListener(updateUI);
    }
  }

  @override
  void dispose() {
    _cancelActions();
    widget.manager.removeListener(updateUI);
    tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sources = widget.manager.isClosing
        ? <ComicSource>[]
        : widget.manager.all();
    return Column(
      children: [
        _sourceAppbar(context, 'Comic Source'.tl),
        Expanded(
          child: NestedScrollView(
            headerSliverBuilder: (context, innerScrolled) => [
              SliverToBoxAdapter(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: FilledButton.icon(
                          onPressed: _addSource,
                          icon: const Icon(Icons.add),
                          label: Text('Add source'.tl),
                        ),
                      ),
                    ),
                    TabBar(
                      controller: tabs,
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      tabs: [
                        for (final title in [
                          'Installed'.tl,
                          'Source repositories'.tl,
                        ])
                          Tab(
                            height:
                                (MediaQuery.textScalerOf(context).scale(14) *
                                            1.5 +
                                        24)
                                    .clamp(48, double.infinity),
                            text: title,
                          ),
                      ],
                    ),
                    const SourceInstallationSummary(),
                  ],
                ),
              ),
            ],
            body: Builder(
              builder: (context) => TabBarView(
                controller: tabs,
                children: [
                  SmoothCustomScrollView(
                    controller: PrimaryScrollController.of(context),
                    slivers: [
                      buildCard(context),
                      if (sources.isEmpty)
                        SliverToBoxAdapter(
                          child: SourceManagementEmptyState(
                            icon: Icons.extension_outlined,
                            title: 'No installed sources'.tl,
                            description:
                                'Add a source link or JS/JSON file, or browse your saved repositories.'
                                    .tl,
                          ),
                        ),
                      for (var source in sources)
                        _SliverComicSource(
                          key: ObjectKey(source),
                          source: source,
                          manager: widget.manager,
                          edit: edit,
                          update: update,
                          delete: delete,
                        ),
                      SliverPadding(
                        padding: EdgeInsets.only(
                          bottom: context.padding.bottom,
                        ),
                      ),
                    ],
                  ),
                  const SourceRepositoriesPanel(),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  void delete(ComicSource source) async {
    final manager = widget.manager;
    final refresh = widget.refresh;
    final path = App.dataPath;
    final task = WindowSelectionTask(context);
    bool canPresent() =>
        mounted &&
        identical(widget.manager, manager) &&
        !manager.isClosing &&
        path == App.dataPath &&
        task.canPresent;
    if (!canPresent() ||
        !identical(manager.find(source.key), source) ||
        _deletions.containsKey(source)) {
      return;
    }
    final previousFailure = _deletionFailures[source];
    if (previousFailure != null) {
      context.showMessage(message: sourceFailureMessage(previousFailure));
      return;
    }
    _deletions[source] = task;
    try {
      await task.run<void>((_) async {
        if (!canPresent()) throw const SelectionCancelled();
        final confirmed = await showSourceActionDialog(
          context: context,
          task: task,
          canPresent: canPresent,
          builder: (context, finish) => ContentDialog(
            title: 'Uninstall source'.tl,
            content: Text(
              "Delete comic source '@n' ?".tlParams({'n': source.name}),
            ).paddingHorizontal(16).paddingVertical(8),
            actions: [
              FilledButton(
                onPressed: () => finish(true),
                style: FilledButton.styleFrom(
                  backgroundColor: context.colorScheme.error,
                ),
                child: Text('Confirm'.tl),
              ),
            ],
          ),
        );
        if (confirmed != true || !canPresent()) return;
        task.checkActive();
        // Once admitted, deletion belongs to the manager even if UI closes.
        await manager.uninstallScript(
          source,
          validate: () {
            if (path != App.dataPath) {
              throw StateError(
                'Source deletion belongs to a different data directory',
              );
            }
          },
        );
        if (canPresent()) refresh?.call();
      });
    } on SelectionCancelled {
      // The original route or window no longer accepts confirmation.
    } catch (error, stack) {
      if (error is SourceMutationFailure) _deletionFailures[source] = error;
      Log.error('Uninstall comic source', error, stack);
      if (mounted && canPresent()) {
        context.showMessage(message: sourceFailureMessage(error));
      }
    } finally {
      _deletions.remove(source);
    }
  }

  void edit(ComicSource source) async {
    final task = WindowSelectionTask(context);
    final manager = widget.manager;
    if (!task.canPresent || manager.isClosing || !_openingEditors.add(source)) {
      return;
    }
    final files = widget.scriptFiles;
    final dataPath = App.dataPath;
    final cachePath = App.cachePath;
    void validatePath() {
      if (App.dataPath != dataPath) {
        throw StateError('Source editor belongs to a different data directory');
      }
    }

    void checkOrigin() {
      task.checkActive();
      validatePath();
      if (manager.isClosing || !identical(manager.find(source.key), source)) {
        throw StateError('The source is no longer available to this editor');
      }
    }

    try {
      checkOrigin();
      final session = SourceScriptSession(
        source: source,
        replace: (target, script) =>
            manager.replaceScript(target, script, validate: validatePath),
      );
      final prepared = await task.run<({String? draft, String? script})>((
        _,
      ) async {
        if (App.isDesktop) {
          try {
            final draft = await files.createDraft(
              sourcePath: source.filePath,
              cachePath: cachePath,
            );
            checkOrigin();
            await files.openEditor(draft);
            checkOrigin();
            return (draft: draft, script: null);
          } on SelectionCancelled {
            rethrow;
          } catch (_) {
            // Preserve the built-in fallback only for this original owner.
            checkOrigin();
          }
        }
        final script = await files.read(source.filePath);
        checkOrigin();
        return (draft: null, script: script);
      });
      checkOrigin();
      if (!mounted) return;
      if (prepared.draft case final draft?) {
        await showDialog<void>(
          context: context,
          builder: (_) => SourceScriptReloadDialog(
            read: () => files.read(draft),
            onSave: session.save,
            canSave: () => session.canSave,
          ),
        );
      } else {
        await context.to(
          () => SourceScriptEditor(
            script: prepared.script!,
            onSave: session.save,
            canSave: () => session.canSave,
          ),
        );
      }
    } on SelectionCancelled {
      // Preparation still settles under its original application/window.
    } catch (error) {
      if (mounted && task.canPresent) {
        context.showMessage(message: error.toString());
      }
    } finally {
      _openingEditors.remove(source);
    }
  }

  void update(ComicSource source) async {
    final service = widget.updates;
    final manager = widget.manager;
    if (service == null) return;
    final prompt = SourceUpdatePrompt(
      context: context,
      source: source,
      manager: manager,
      service: service,
      isCurrent: () =>
          mounted &&
          identical(widget.updates, service) &&
          identical(widget.manager, manager),
    );
    _updates.add(prompt);
    try {
      await prompt.run();
    } finally {
      _updates.remove(prompt);
    }
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
              SourceUpdateCheckButton(
                manager: widget.manager,
                service: widget.updates,
                refresh: widget.refresh,
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

  Future<void> _addSource() => showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const SourceImportDialog(),
  );

  void help() {
    launchUrlString(
      "https://github.com/CyrilPeng/venera-next/blob/main/doc/development/source_debugging.zh.md",
    );
  }
}

class _CallbackSetting extends StatefulWidget {
  const _CallbackSetting({
    super.key,
    required this.setting,
    required this.source,
    required this.manager,
  });

  final MapEntry<String, Map<String, dynamic>> setting;

  final ComicSource source;
  final ComicSourceManager manager;

  @override
  State<_CallbackSetting> createState() => _CallbackSettingState();
}

class _CallbackSettingState extends State<_CallbackSetting> {
  String get key => widget.setting.key;

  String get buttonText => widget.setting.value['buttonText'] ?? "Click";

  String get title => widget.setting.value['title'] ?? key;

  bool isLoading = false;
  WindowSelectionTask? _task;

  @override
  void dispose() {
    _task?.cancel();
    super.dispose();
  }

  Future<void> onClick() async {
    if (!mounted || isLoading) return;
    final task = WindowSelectionTask(context);
    final source = widget.source;
    final manager = widget.manager;
    bool current() =>
        mounted &&
        identical(widget.source, source) &&
        identical(widget.manager, manager) &&
        !manager.isClosing &&
        identical(manager.find(source.key), source);
    if (!task.canPresent || !current()) return;
    final callback = widget.setting.value['callback'];
    _task = task;
    setState(() => isLoading = true);
    try {
      await task.run<void>((_) async {
        if (!current()) throw const SelectionCancelled();
        await invokeJsCallbackToCompletion(callback, []);
      });
    } on SelectionCancelled {
      // UI cancellation still joins the original accepted invocation.
    } catch (error, stack) {
      Log.error('Source setting callback', error, stack);
      if (mounted && current() && task.canPresent) {
        context.showMessage(message: error.toString());
      }
    } finally {
      _task = null;
      if (mounted && isLoading) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = buttonText.ts(widget.source.key);
    final translatedTitle = title.ts(widget.source.key);
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final text = TextPainter(
          text: TextSpan(text: label, style: const TextStyle(fontSize: 14)),
          textScaler: scaler,
          textDirection: Directionality.of(context),
        )..layout();
        // Keep the usual tile padding and enough title space beside the button.
        final stacked =
            scaler.scale(14) > 14 ||
            text.width + 32 + 56 + 40 >= constraints.maxWidth;
        text.layout(
          maxWidth: (constraints.maxWidth - 64).clamp(1, double.infinity),
        );
        final height = (text.height + 16).clamp(48.0, double.infinity);
        text.dispose();
        final button = Semantics(
          button: true,
          enabled: !isLoading,
          label: isLoading ? label : null,
          child: Button.normal(
            onPressed: onClick,
            isLoading: isLoading,
            padding: stacked
                ? const EdgeInsets.symmetric(horizontal: 16, vertical: 8)
                : null,
            child: Text(label),
          ),
        );
        if (!stacked) {
          return ListTile(
            title: Text(translatedTitle),
            trailing: button.fixHeight(32),
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                translatedTitle,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: BoxConstraints(minHeight: height),
                child: button,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SliverComicSource extends StatefulWidget {
  const _SliverComicSource({
    super.key,
    required this.source,
    required this.manager,
    required this.edit,
    required this.update,
    required this.delete,
  });

  final ComicSource source;
  final ComicSourceManager manager;

  final void Function(ComicSource source) edit;
  final void Function(ComicSource source) update;
  final void Function(ComicSource source) delete;

  @override
  State<_SliverComicSource> createState() => _SliverComicSourceState();
}

class _SliverComicSourceState extends SettingsSaveState<_SliverComicSource> {
  JsCallbackScope? _settingsCallbacks;

  @override
  void dispose() {
    _settingsCallbacks?.dispose();
    super.dispose();
  }

  ComicSource get source => widget.source;

  bool expanded = false;

  bool _current(ComicSource target) =>
      mounted &&
      identical(source, target) &&
      !widget.manager.isClosing &&
      identical(widget.manager.find(target.key), target);

  Future<void> _saveValue(ComicSource target, String key, dynamic value) async {
    if (!_current(target) ||
        !acceptsSettingsChanges ||
        ModalRoute.of(context)?.isCurrent == false ||
        !NavigationAdmission.allows(context)) {
      return;
    }
    SourceDataEdit? edit;
    await saveSetting(
      (target, key),
      () => (edit ??= target.prepareDataEdit((draft) {
        (draft['settings'] ??= <String, dynamic>{})[key] = value;
      })).save(),
      isCurrent: () => _current(target),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!expanded) {
      _settingsCallbacks?.dispose();
      _settingsCallbacks = null;
    }
    final newVersion = widget.manager.isClosing
        ? null
        : widget.manager.availableUpdates[source.key];
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
          SliverToBoxAdapter(child: settingsSaveStatus),
          SliverToBoxAdapter(
            child: protectSettings(
              Column(children: buildSourceSettings().toList()),
            ),
          ),
          SliverToBoxAdapter(
            child: protectSettings(Column(children: _buildAccount().toList())),
          ),
        ],
        const SliverToBoxAdapter(child: Divider(indent: 16, endIndent: 16)),
      ],
    );
  }

  Iterable<Widget> buildSourceSettings() sync* {
    final target = source;
    // Try to get dynamic settings first (for getters), fall back to cached settings
    _settingsCallbacks?.dispose();
    final callbacks = _settingsCallbacks = source.createSettingsCallbackScope();
    var settingsMap =
        source.getSettingsDynamic(callbacks: callbacks) ?? source.settings;

    if (settingsMap == null) {
      return;
    }
    for (var item in settingsMap.entries) {
      var key = item.key;
      String type = item.value['type'];
      try {
        if (type == "select") {
          final options = (item.value['options'] as List);
          final current =
              source.data['settings']?[key] ?? item.value['default'];
          yield Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text((item.value['title'] as String).ts(target.key)),
                const SizedBox(height: 8),
                Semantics(
                  label: (item.value['title'] as String).ts(target.key),
                  child: DropdownButtonFormField<dynamic>(
                    key: ValueKey((key, current)),
                    initialValue:
                        options.any((option) => option['value'] == current)
                        ? current
                        : null,
                    isExpanded: true,
                    itemHeight: null,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                    ),
                    items: [
                      for (final option in options)
                        DropdownMenuItem<dynamic>(
                          value: option['value'],
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              (option['text'] ?? option['value']).toString().ts(
                                target.key,
                              ),
                            ),
                          ),
                        ),
                    ],
                    onChanged: acceptsSettingsChanges
                        ? (value) => unawaited(_saveValue(target, key, value))
                        : null,
                  ),
                ),
              ],
            ),
          );
        } else if (type == "switch") {
          var current = source.data['settings']?[key] ?? item.value['default'];
          yield ListTile(
            title: Text((item.value['title'] as String).ts(source.key)),
            trailing: Switch(
              value: current,
              onChanged: (v) {
                unawaited(_saveValue(target, key, v));
              },
            ),
          );
        } else if (type == "input") {
          var current =
              source.data['settings']?[key] ?? item.value['default'] ?? '';
          yield ListTile(
            title: Text((item.value['title'] as String).ts(source.key)),
            subtitle: Text(
              current,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              icon: const Icon(Icons.edit),
              tooltip: 'Edit'.tl,
              onPressed: () async {
                if (!acceptsSettingsChanges || !_current(target)) return;
                await showDialog<void>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => _SourceSettingInput(
                    source: target,
                    settingKey: key,
                    title: (item.value['title'] as String).ts(target.key),
                    initialValue: current,
                    validator: item.value['validator'] == null
                        ? null
                        : RegExp(item.value['validator']),
                  ),
                );
                if (_current(target)) setState(() {});
              },
            ),
          );
        } else if (type == "callback") {
          yield _CallbackSetting(
            key: ValueKey(key),
            setting: item,
            source: target,
            manager: widget.manager,
          );
        }
      } catch (e, s) {
        Log.error("ComicSourcePage", "Failed to build a setting\n$e\n$s");
      }
    }
  }

  Iterable<Widget> _buildAccount() sync* {
    final target = source;
    final manager = widget.manager;
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
          if (_current(target)) setState(() {});
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
        bool loading = savingSettings;
        yield ListTile(
          title: Text("Re-login".tl),
          subtitle: Text("Click if login expired".tl),
          onTap: () async {
            if (savingSettings ||
                !acceptsSettingsChanges ||
                !_current(target)) {
              return;
            }
            final List account = target.data['account'];
            final attempt = SourceLoginAttempt.password(
              target,
              account[0],
              account[1],
            );
            await saveSetting((target, 'account'), () async {
              final result = await attempt.save();
              if (mounted && _current(target)) {
                context.showMessage(
                  message: result.error ? result.errorMessage! : 'Success'.tl,
                );
              }
            }, isCurrent: () => _current(target));
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
        onTap: () async {
          if (!_current(target) || savingSettings || !acceptsSettingsChanges) {
            return;
          }
          Future<void>? logout;
          SourceDataEdit? edit;
          await saveSetting(
            (target, 'account'),
            () async {
              edit ??= target.prepareDataEdit(
                (draft) => draft.remove('account'),
              );
              await (logout ??= Future<void>.sync(target.account!.logout));
              await edit!.save();
            },
            isCurrent: () => _current(target),
            onSaved: () {
              manager.notifyStateChange();
            },
          );
        },
        trailing: const Icon(Icons.logout),
      );
    }
  }
}

class _SourceSettingInput extends StatefulWidget {
  const _SourceSettingInput({
    required this.source,
    required this.settingKey,
    required this.title,
    required this.initialValue,
    this.validator,
  });
  final ComicSource source;
  final String settingKey;
  final String title;
  final String initialValue;
  final RegExp? validator;
  @override
  State<_SourceSettingInput> createState() => _SourceSettingInputState();
}

class _SourceSettingInputState extends SettingsSaveState<_SourceSettingInput> {
  late final input = TextEditingController(text: widget.initialValue);
  String? error;
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (!acceptsSettingsChanges || savingSettings || hasSettingsSaveError) {
      return;
    }
    final value = input.text;
    if (widget.validator?.hasMatch(value) == false) {
      setState(() => error = 'Invalid input'.tl);
      return;
    }
    final target = widget.source;
    final key = widget.settingKey;
    SourceDataEdit? edit;
    await saveSetting(
      key,
      () => (edit ??= target.prepareDataEdit((draft) {
        (draft['settings'] ??= <String, dynamic>{})[key] = value;
      })).save(),
      onSaved: () {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(leaveSettings());
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    scrollable: true,
    content: Semantics(
      label: widget.title,
      child: TextField(
        controller: input,
        autofocus: true,
        enabled:
            acceptsSettingsChanges && !savingSettings && !hasSettingsSaveError,
        decoration: InputDecoration(errorText: error),
        onSubmitted: (_) => save(),
      ),
    ),
    actions: [
      settingsSaveStatus,
      TextButton(onPressed: leaveSettings, child: Text('Cancel'.tl)),
      FilledButton(
        onPressed:
            acceptsSettingsChanges && !savingSettings && !hasSettingsSaveError
            ? save
            : null,
        child: Text('Save'.tl),
      ),
    ],
  );
}

class _LoginPage extends StatefulWidget {
  const _LoginPage({required this.config, required this.source});

  final AccountConfig config;

  final ComicSource source;

  @override
  State<_LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends SettingsSaveState<_LoginPage> {
  String username = "";
  String password = "";
  bool get loading => savingSettings;
  String? _loginError;

  final Map<String, String> _cookies = {};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _sourceAppbar(context, 'Login'.tl),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Center(
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
                        enabled:
                            widget.config.login != null &&
                            !loading &&
                            !hasSettingsSaveError &&
                            acceptsSettingsChanges,
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
                        enabled:
                            widget.config.login != null &&
                            !loading &&
                            !hasSettingsSaveError &&
                            acceptsSettingsChanges,
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
                        enabled:
                            widget.config.validateCookies != null &&
                            !loading &&
                            !hasSettingsSaveError &&
                            acceptsSettingsChanges,
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
                          Flexible(
                            child: Text("Login with password is disabled".tl),
                          ),
                        ],
                      )
                    else
                      FilledButton(
                        onPressed:
                            loading ||
                                hasSettingsSaveError ||
                                !acceptsSettingsChanges
                            ? null
                            : login,
                        child: Text("Continue".tl),
                      ),
                    const SizedBox(height: 24),
                    if (_loginError != null)
                      Text(
                        _loginError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    settingsSaveStatus,
                    if (widget.config.loginWebsite != null)
                      TextButton(
                        onPressed:
                            loading ||
                                hasSettingsSaveError ||
                                !acceptsSettingsChanges
                            ? null
                            : () {
                                unawaited(loginWithWebview());
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
                            Flexible(child: Text("Create Account".tl)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> login() async {
    if (loading || hasSettingsSaveError || !acceptsSettingsChanges) return;
    final config = widget.config;
    if (config.login != null && (username.isEmpty || password.isEmpty)) {
      showToast(
        message: 'Cannot be empty'.tl,
        icon: const Icon(Icons.error_outline),
        context: context,
      );
      return;
    }
    if (config.login == null && config.validateCookies == null) return;
    final target = widget.source;
    final attempt = config.login != null
        ? SourceLoginAttempt.password(target, username, password)
        : SourceLoginAttempt.cookies(
            target,
            config.cookieFields!.map((e) => _cookies[e] ?? '').toList(),
          );
    bool success = false;
    _loginError = null;
    await saveSetting(
      'login',
      () async {
        final result = await attempt.save();
        success = !result.error && result.data;
        if (!success && mounted) {
          setState(
            () => _loginError = result.errorMessage ?? 'Invalid cookies'.tl,
          );
        }
      },
      onSaved: () {
        if (success) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(leaveSettings());
          });
        }
      },
    );
  }

  Future<void> loginWithWebview() async {
    if (savingSettings || hasSettingsSaveError || !acceptsSettingsChanges) {
      return;
    }
    final target = widget.source;
    CookieJarSql? cookieJar;
    await saveSetting('web-capture', () async {
      cookieJar = await SingleInstanceCookieJar.captureInstance();
    });
    if (cookieJar == null ||
        !mounted ||
        !acceptsSettingsChanges ||
        ModalRoute.of(context)?.isCurrent != true ||
        !NavigationAdmission.allows(context) ||
        !identical(ComicSource.find(target.key), target)) {
      return;
    }
    await context.to(
      () => _SourceWebLoginPage(source: target, cookieJar: cookieJar!),
    );
    if (mounted &&
        target.isLogged &&
        identical(ComicSource.find(target.key), target)) {
      await leaveSettings();
    }
  }
}

class _SourceWebLoginPage extends StatefulWidget {
  const _SourceWebLoginPage({required this.source, required this.cookieJar});
  final ComicSource source;
  final CookieJarSql cookieJar;
  @override
  State<_SourceWebLoginPage> createState() => _SourceWebLoginPageState();
}

class _SourceWebLoginPageState extends SettingsSaveState<_SourceWebLoginPage> {
  late String url = widget.source.account!.loginWebsite!;
  String title = '';
  DesktopWebview? _desktop;
  bool _finished = false;
  String? _error;
  WindowFrameController? _window;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _window = context
        .dependOnInheritedWidgetOfExactType<WindowFrameController>();
  }

  @override
  void initState() {
    super.initState();
    if (App.isLinux) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_openDesktop());
      });
    }
  }

  Future<void> _openDesktop() async {
    await saveSetting('web-open', () async {
      if (!await DesktopWebview.isAvailable()) {
        throw StateError('Webview is not available'.tl);
      }
      if (!mounted || !acceptsSettingsChanges) return;
      final desktop = _desktop = DesktopWebview(
        initialUrl: url,
        onTitleChange: (value, controller) {
          title = value;
          _validateDesktop(controller);
        },
        onNavigation: (value, controller) {
          url = value;
          _validateDesktop(controller);
        },
        onClose: () {
          if (mounted && !_finished) unawaited(leaveSettings());
        },
      );
      await desktop.open();
    });
  }

  void _validateDesktop(DesktopWebview controller) {
    final capturedUrl = url;
    unawaited(
      _validate(capturedUrl, title, () async {
        final values = await controller.getCookies(capturedUrl);
        final cookies = [
          for (final entry in values.entries) io.Cookie(entry.key, entry.value),
        ];
        final raw = await controller.evaluateJavascript(
          'JSON.stringify(window.localStorage);',
        );
        final decoded = jsonDecode(raw ?? '{}');
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('Invalid localStorage');
        }
        return (cookies: cookies, storage: decoded);
      }),
    );
  }

  void _validateEmbedded(InAppWebViewController controller) {
    final capturedUrl = url;
    unawaited(
      _validate(capturedUrl, title, () async {
        final cookies = await controller.getCookies(capturedUrl) ?? [];
        final items = await controller.webStorage.localStorage.getItems();
        return (
          cookies: cookies,
          storage: <String, dynamic>{
            for (final item in items)
              if (item.key != null) item.key!: item.value,
          },
        );
      }),
    );
  }

  Future<void> _validate(
    String capturedUrl,
    String capturedTitle,
    Future<({List<io.Cookie> cookies, Map<String, dynamic> storage})> Function()
    read,
  ) async {
    if (!mounted ||
        _finished ||
        savingSettings ||
        hasSettingsSaveError ||
        !acceptsSettingsChanges ||
        ModalRoute.of(context)?.isCurrent != true ||
        !NavigationAdmission.allows(context)) {
      return;
    }
    final source = widget.source;
    try {
      if (source.account!.checkLoginStatus?.call(capturedUrl, capturedTitle) !=
          true) {
        return;
      }
    } catch (error, stack) {
      Log.error('Source web login', error, stack);
      setState(() => _error = error.toString());
      return;
    }
    ({List<io.Cookie> cookies, Map<String, dynamic> storage})? captured;
    SourceDataEdit? edit;
    Future<void>? callback;
    bool cookiesSaved = false;
    await saveSetting(
      'web-login',
      () async {
        edit ??= source.prepareDataEdit((draft) {
          draft['_localStorage'] = captured!.storage;
          draft['account'] = 'ok';
        });
        edit!.checkCurrent();
        captured ??= await read();
        edit!.checkCurrent();
        if (!cookiesSaved) {
          await AppDataOperations.instance.access(() async {
            edit!.checkCurrent();
            await widget.cookieJar.saveFromResponseAsync(
              Uri.parse(capturedUrl),
              captured!.cookies,
            );
          });
          cookiesSaved = true;
        }
        await edit!.save();
        callback ??= Future<void>.sync(
          () => source.account!.onLoginWithWebviewSuccess?.call(),
        );
        await callback;
        // Include writes accepted by the success callback before reporting login.
        await source.saveData();
      },
      onSaved: () {
        _finished = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(leaveSettings());
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (savingSettings || hasSettingsSaveError || _error != null)
        Material(
          child: SafeArea(
            bottom: false,
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                settingsSaveStatus,
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(_error!),
                  ),
              ],
            ),
          ),
        ),
      Expanded(
        child: App.isLinux
            ? Scaffold(
                appBar: Appbar(title: Text('Login with webview'.tl)),
                body: Center(child: Text('Login with webview'.tl)),
              )
            : AbsorbPointer(
                absorbing: savingSettings || hasSettingsSaveError,
                child: AppWebview(
                  initialUrl: widget.source.account!.loginWebsite!,
                  onNavigation: (value, controller) {
                    url = value;
                    _validateEmbedded(controller);
                    return false;
                  },
                  onTitleChange: (value, controller) {
                    title = value;
                    _validateEmbedded(controller);
                  },
                ),
              ),
      ),
    ],
  );

  @override
  void dispose() {
    final desktop = _desktop;
    if (desktop != null) {
      final closing = desktop.close();
      _window?.trackExitTask(closing);
      unawaited(
        closing.catchError((Object error, StackTrace stack) {
          Log.error('Source webview close', error, stack);
        }),
      );
    }
    super.dispose();
  }
}
