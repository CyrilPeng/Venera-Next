import 'source_failure_presentation.dart';
import 'source_failure.dart';
import 'dart:async';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
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
import 'package:venera_next/network/app_dio.dart';
import 'package:venera_next/network/cookie_jar.dart';
import 'package:venera_next/routing/webview.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

import 'parser.dart' show compareSemVer;
import 'source_installation_widgets.dart';
import 'source_translation.dart';
import 'source_repositories.dart';
import 'source_repository_page.dart';
import 'source_script_editor.dart';
import 'source_import_dialog.dart';
import 'source_update_service.dart';

class ComicSourcePage extends StatelessWidget {
  const ComicSourcePage({super.key});

  @visibleForTesting
  static SourceUpdateService updateService = SourceUpdateService.instance;

  static Future<void> update(
    ComicSource source, [
    bool showLoading = true,
  ]) async {
    final service = updateService;
    if (!showLoading) return service.update(source);
    if (service.isUpdating(source.key)) return;
    final loadingContext = App.rootContext;
    LoadingDialogController? controller;
    try {
      controller = showLoadingDialog(
        loadingContext,
        onCancel: () => service.cancel(source.key),
        barrierDismissible: false,
      );
      await service.update(
        source,
        onCommit: () {
          if (loadingContext.mounted) controller?.close();
        },
      );
    } catch (error) {
      if (error is SourceFailure && error.code == SourceFailureCode.cancelled) {
        return;
      }
      final context = App.rootNavigatorKey.currentContext;
      if (context != null && context.mounted) {
        context.showMessage(
          message: error is DioException
              ? 'Network error'.tl
              : sourceFailureMessage(error),
        );
      }
    } finally {
      if (loadingContext.mounted) controller?.close();
    }
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
                      if (ComicSource.isEmpty)
                        SliverToBoxAdapter(
                          child: SourceManagementEmptyState(
                            icon: Icons.extension_outlined,
                            title: 'No installed sources'.tl,
                            description:
                                'Add a source link or JS/JSON file, or browse your saved repositories.'
                                    .tl,
                          ),
                        ),
                      for (var source in ComicSource.all())
                        _SliverComicSource(
                          key: ObjectKey(source),
                          source: source,
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

  void delete(ComicSource source) {
    showConfirmDialog(
      context: App.rootContext,
      title: 'Uninstall source'.tl,
      content: "Delete comic source '@n' ?".tlParams({"n": source.name}),
      btnColor: context.colorScheme.error,
      onConfirm: () async {
        await ComicSourceManager().uninstallScript(source);
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
          context: context,
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
                              updateDialog(
                                () => error = sourceFailureMessage(e),
                              );
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
      await ComicSourcePage.updateService.checkUpdates();
      if (!mounted) return;
      final result = ComicSourcePage.updateService.lastUpdateCheck!;
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
                      '${'Some sources could not be checked.'.tl}\n${result.failures.map((failure) => failure.format(sourceFailureMessage)).join('\n')}',
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
            failures.add('${source.name}: ${sourceFailureMessage(error)}');
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
    if (isLoading) return;
    try {
      var func = widget.setting.value['callback'];
      var result = func([]);
      if (result is Future) {
        setState(() {
          isLoading = true;
        });
        await result;
      }
    } catch (error, stack) {
      Log.error('Source setting callback', error, stack);
      if (mounted) context.showMessage(message: error.toString());
    } finally {
      if (mounted && isLoading) {
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
      identical(ComicSource.find(target.key), target);

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
          yield _CallbackSetting(setting: item, sourceKey: source.key);
        }
      } catch (e, s) {
        Log.error("ComicSourcePage", "Failed to build a setting\n$e\n$s");
      }
    }
  }

  Iterable<Widget> _buildAccount() sync* {
    final target = source;
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
              ComicSourceManager().notifyStateChange();
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
