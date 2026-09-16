import 'dart:convert';
import 'dart:io' as io;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/code.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/pop_up_widget.dart';
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

import 'parser.dart';
import 'source_translation.dart';

class ComicSourcePage extends StatelessWidget {
  const ComicSourcePage({super.key});

  @visibleForTesting
  static Dio Function()? debugCreateDio;

  static Dio _createDio() => debugCreateDio?.call() ?? AppDio();

  static Future<String?> _downloadSource(
    String url, {
    bool showLoading = true,
    CancelToken? cancelToken,
  }) async {
    final uri = _sourceHttpUri(url);
    final token = cancelToken ?? CancelToken();
    final dio = _createDio();
    final loadingContext = showLoading ? App.rootContext : null;
    final controller = loadingContext == null
        ? null
        : showLoadingDialog(
            loadingContext,
            onCancel: token.cancel,
            barrierDismissible: false,
          );
    try {
      final res = await dio.get<String>(
        uri.toString(),
        cancelToken: token,
        options: Options(
          responseType: ResponseType.plain,
          headers: {"cache-time": "no"},
        ),
      );
      if (token.isCancelled) return null;
      return res.data ?? '';
    } catch (_) {
      if (token.isCancelled) return null;
      rethrow;
    } finally {
      if (loadingContext?.mounted ?? false) controller?.close();
      dio.close();
    }
  }

  static Future<void> update(
    ComicSource source, [
    bool showLoading = true,
  ]) async {
    var sourceRemoved = false;
    try {
      final content = await _downloadSource(
        source.url,
        showLoading: showLoading,
      );
      if (content == null) return;
      ComicSourceManager().remove(source.key);
      sourceRemoved = true;
      await ComicSourceParser().parse(content, source.filePath);
      await io.File(source.filePath).writeAsString(content);
      if (ComicSourceManager().availableUpdates.containsKey(source.key)) {
        ComicSourceManager().availableUpdates.remove(source.key);
      }
    } catch (e, s) {
      Log.error("Update comic source", "$e\n$s");
      if (showLoading) {
        final context = App.rootNavigatorKey.currentContext;
        if (context != null && context.mounted) {
          context.showMessage(message: _sourceErrorMessage(e));
        }
      } else {
        rethrow;
      }
    } finally {
      if (sourceRemoved) {
        await ComicSourceManager().reload();
        if (showLoading) App.forceRebuild();
      }
    }
  }

  static Future<int> checkComicSourceUpdate() async {
    if (ComicSource.all().isEmpty) {
      return 0;
    }
    final sourceListUrl = appdata.settings['comicSourceListUrl']
        ?.toString()
        .trim();
    if (sourceListUrl == null || sourceListUrl.isEmpty) {
      return 0;
    }
    var dio = AppDio();
    var res = await dio.get<String>(sourceListUrl);
    if (res.statusCode != 200) {
      return -1;
    }
    var list = jsonDecode(res.data!) as List;
    var versions = <String, String>{};
    for (var source in list) {
      versions[source['key']] = source['version'];
    }
    var shouldUpdate = <String>[];
    for (var source in ComicSource.all()) {
      if (versions.containsKey(source.key) &&
          compareSemVer(versions[source.key]!, source.version)) {
        shouldUpdate.add(source.key);
      }
    }
    if (shouldUpdate.isNotEmpty) {
      var updates = <String, String>{};
      for (var key in shouldUpdate) {
        updates[key] = versions[key]!;
      }
      ComicSourceManager().updateAvailableUpdates(updates);
    }
    return shouldUpdate.length;
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

class _BodyState extends State<_Body> {
  var url = "";
  CancelToken? _addSourceToken;

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
    _addSourceToken?.cancel();
    ComicSourceManager().removeListener(updateUI);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text('Comic Source'.tl), style: AppbarStyle.shadow),
        buildCard(context),
        for (var source in ComicSource.all())
          _SliverComicSource(
            key: ValueKey(source.key),
            source: source,
            edit: edit,
            update: update,
            delete: delete,
          ),
        SliverPadding(padding: EdgeInsets.only(bottom: context.padding.bottom)),
      ],
    );
  }

  void delete(ComicSource source) {
    showConfirmDialog(
      context: App.rootContext,
      title: "Delete".tl,
      content: "Delete comic source '@n' ?".tlParams({"n": source.name}),
      btnColor: context.colorScheme.error,
      onConfirm: () {
        var file = File(source.filePath);
        file.delete();
        ComicSourceManager().remove(source.key);
        _validatePages();
        App.forceRebuild();
      },
    );
  }

  void edit(ComicSource source) async {
    if (App.isDesktop) {
      try {
        await Process.run("code", [source.filePath], runInShell: true);
        await showDialog(
          context: App.rootContext,
          builder: (context) => AlertDialog(
            title: Text("Reload Configs".tl),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text("Cancel".tl),
              ),
              TextButton(
                onPressed: () async {
                  await ComicSourceManager().reload();
                  App.forceRebuild();
                },
                child: Text("Continue".tl),
              ),
            ],
          ),
        );
        return;
      } catch (e) {
        //
      }
    }
    context.to(
      () => _EditFilePage(source.filePath, () async {
        await ComicSourceManager().reload();
        setState(() {});
      }),
    );
  }

  void update(ComicSource source, [bool showLoading = true]) {
    ComicSourcePage.update(source, showLoading);
  }

  Widget buildCard(BuildContext context) {
    return SliverToBoxAdapter(
      child: SizedBox(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text("Add comic source".tl),
              leading: const Icon(Icons.dashboard_customize),
            ),
            TextField(
              decoration: InputDecoration(
                hintText: "URL",
                border: const UnderlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                suffix: IconButton(
                  onPressed: () => handleAddSource(url),
                  icon: const Icon(Icons.check),
                ),
              ),
              onChanged: (value) {
                url = value;
              },
              onSubmitted: handleAddSource,
            ).paddingHorizontal(16).paddingBottom(8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  icon: Icon(Icons.article_outlined),
                  label: Text("Comic Source list".tl),
                  onPressed: () {
                    showPopUpWidget(
                      App.rootContext,
                      _ComicSourceList(handleAddSource),
                    );
                  },
                ),
                FilledButton.tonalIcon(
                  icon: Icon(Icons.file_open_outlined),
                  label: Text("Use a config file".tl),
                  onPressed: _selectFile,
                ),
                FilledButton.tonalIcon(
                  icon: Icon(Icons.help_outline),
                  label: Text("Help".tl),
                  onPressed: help,
                ),
                _CheckUpdatesButton(),
              ],
            ).paddingHorizontal(12).paddingVertical(8),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _selectFile() async {
    final file = await selectFile(ext: ["js"]);
    if (file == null) return;
    try {
      var fileName = file.name;
      var bytes = await file.readAsBytes();
      var content = utf8.decode(bytes);
      await addSource(content, fileName);
    } catch (e, s) {
      App.rootContext.showMessage(message: e.toString());
      Log.error("Add comic source", "$e\n$s");
    }
  }

  void help() {
    launchUrlString(
      "https://github.com/CyrilPeng/venera-next/blob/main/doc/comic_source.md",
    );
  }

  Future<void> handleAddSource(String url) async {
    if (url.trim().isEmpty || _addSourceToken != null) {
      return;
    }
    final token = CancelToken();
    _addSourceToken = token;
    try {
      final uri = _sourceHttpUri(url);
      final fileName = uri.pathSegments.lastOrNull;
      if (fileName == null ||
          fileName.isEmpty ||
          fileName == '.' ||
          fileName == '..' ||
          fileName.contains('/') ||
          fileName.contains('\\')) {
        throw ComicSourceParseException('Invalid url config'.tl);
      }
      final content = await ComicSourcePage._downloadSource(
        uri.toString(),
        cancelToken: token,
      );
      if (content == null || token.isCancelled || !mounted) return;
      await addSource(content, fileName);
    } catch (e, s) {
      if (token.isCancelled || !mounted) return;
      context.showMessage(message: _sourceErrorMessage(e));
      Log.error("Add comic source", "$e\n$s");
    } finally {
      _addSourceToken = null;
    }
  }

  Future<void> addSource(String js, String fileName) async {
    var comicSource = await ComicSourceParser().createAndParse(js, fileName);
    ComicSourceManager().add(comicSource);
    _addAllPagesWithComicSource(comicSource);
    appdata.saveData();
    App.forceRebuild();
  }
}

class _ComicSourceList extends StatefulWidget {
  const _ComicSourceList(this.onAdd);

  final Future<void> Function(String) onAdd;

  @override
  State<_ComicSourceList> createState() => _ComicSourceListState();
}

class _ComicSourceListState extends State<_ComicSourceList> {
  ({Uri uri, List<Map<String, dynamic>> entries})? _list;
  bool _loading = false;
  int _loadGeneration = 0;
  CancelToken? _loadToken;
  final controller = TextEditingController();

  Future<void> load() async {
    final generation = ++_loadGeneration;
    _loadToken?.cancel();
    final token = CancelToken();
    _loadToken = token;
    final requestedUrl = controller.text.trim();
    setState(() {
      _list = null;
      _loading = true;
    });
    Dio? dio;
    try {
      if (requestedUrl.isEmpty) {
        await _saveListUrl('');
        return;
      }
      final uri = _sourceHttpUri(requestedUrl);
      dio = ComicSourcePage._createDio();
      final res = await dio.get<String>(
        uri.toString(),
        cancelToken: token,
        options: Options(responseType: ResponseType.plain),
      );
      if (!mounted || generation != _loadGeneration || token.isCancelled) {
        return;
      }
      final entries = _sourceListEntries(res.data ?? '');
      // Keep the response and its request URL together, independent of edits.
      setState(() {
        _list = (uri: uri, entries: entries);
        _loading = false;
      });
      await _saveListUrl(uri.toString());
    } catch (e, s) {
      if (!mounted || generation != _loadGeneration || token.isCancelled) {
        return;
      }
      context.showMessage(message: _sourceErrorMessage(e));
      Log.error("Load comic source list", "$e\n$s");
    } finally {
      dio?.close();
      if (mounted && generation == _loadGeneration) {
        _loadToken = null;
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _saveListUrl(String url) async {
    if (appdata.settings['comicSourceListUrl'] == url) return;
    appdata.settings['comicSourceListUrl'] = url;
    await appdata.saveData();
  }

  @override
  void initState() {
    super.initState();
    controller.text = appdata.settings['comicSourceListUrl']?.toString() ?? "";
    load();
  }

  @override
  void dispose() {
    _loadGeneration++;
    _loadToken?.cancel();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(title: "Comic Source".tl, body: buildBody());
  }

  Widget buildBody() {
    var currentKey = ComicSource.all().map((e) => e.key).toList();
    final list = _list;

    return ListView.builder(
      itemCount: (_loading ? 1 : list?.entries.length ?? 0) + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Container(
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            decoration: BoxDecoration(
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
                width: 0.6,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  leading: Icon(Icons.source_outlined),
                  title: Text("Repo URL".tl),
                ),
                TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    hintText: "URL",
                    border: const UnderlineInputBorder(),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  onSubmitted: (_) => load(),
                ).paddingHorizontal(16).paddingBottom(8),
                Text(
                  "The URL should point to a 'index.json' file".tl,
                ).paddingLeft(16),
                Text(
                  "Do not report any issues related to sources to App repo.".tl,
                ).paddingLeft(16),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () {
                        launchUrlString(
                          "https://github.com/CyrilPeng/venera-next/blob/main/doc/comic_source.md",
                        );
                      },
                      child: Text("Help".tl),
                    ),
                    FilledButton.tonal(
                      onPressed: load,
                      child: Text("Refresh".tl),
                    ),
                    const SizedBox(width: 16),
                  ],
                ),
                const SizedBox(height: 16),
              ],
            ),
          );
        }

        if (_loading) {
          return Center(
            child: CircularProgressIndicator(
              strokeWidth: 2,
            ).fixWidth(24).fixHeight(24),
          );
        }

        final entry = list!.entries[index - 1];
        var key = entry["key"];
        var action = currentKey.contains(key)
            ? const Icon(Icons.check, size: 20).paddingRight(8)
            : Button.filled(
                child: Text("Add".tl),
                onPressed: () async {
                  try {
                    final explicitUrl = entry['url'];
                    final reference =
                        explicitUrl is String && explicitUrl.trim().isNotEmpty
                        ? explicitUrl.trim()
                        : entry['fileName'];
                    if (reference is! String || reference.trim().isEmpty) {
                      throw ComicSourceParseException('Invalid url config'.tl);
                    }
                    final referenceUri = Uri.tryParse(reference.trim());
                    if (referenceUri == null) {
                      throw ComicSourceParseException('Invalid url config'.tl);
                    }
                    final uri = _sourceHttpUri(
                      list.uri.resolveUri(referenceUri).toString(),
                    );
                    await widget.onAdd(uri.toString());
                  } catch (e, s) {
                    if (!mounted) return;
                    context.showMessage(message: _sourceErrorMessage(e));
                    Log.error("Add comic source", "$e\n$s");
                  }
                  if (mounted) setState(() {});
                },
              ).fixHeight(32);

        final description = [
          if (entry['version'] != null) entry['version'].toString(),
          if (entry['description'] != null) entry['description'].toString(),
        ].join('\n');

        return ListTile(
          title: Text(entry["name"]),
          subtitle: Text(description),
          trailing: action,
        );
      },
    );
  }
}

Uri _sourceHttpUri(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null ||
      (uri.scheme != 'https' && uri.scheme != 'http') ||
      uri.host.isEmpty) {
    throw ComicSourceParseException('Invalid url config'.tl);
  }
  return uri;
}

String _sourceErrorMessage(Object error) {
  if (error is DioException) return 'Network error'.tl;
  return error.toString();
}

List<Map<String, dynamic>> _sourceListEntries(String content) {
  try {
    final decoded = jsonDecode(content);
    if (decoded is! List ||
        decoded.any(
          (entry) =>
              entry is! Map<String, dynamic> ||
              entry['name'] is! String ||
              entry['key'] is! String,
        )) {
      throw const FormatException('Invalid comic source list');
    }
    return List<Map<String, dynamic>>.unmodifiable(
      decoded.map((entry) => Map<String, dynamic>.unmodifiable(entry)),
    );
  } on FormatException {
    throw ComicSourceParseException('Invalid comic source list'.tl);
  }
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

void _addAllPagesWithComicSource(ComicSource source) {
  var explorePages = appdata.settings['explore_pages'];
  var categoryPages = appdata.settings['categories'];
  var networkFavorites = appdata.settings['favorites'];
  var searchPages = appdata.settings['searchSources'];

  if (source.explorePages.isNotEmpty) {
    for (var page in source.explorePages) {
      if (!explorePages.contains(page.title)) {
        explorePages.add(page.title);
      }
    }
  }
  if (source.categoryData != null &&
      !categoryPages.contains(source.categoryData!.key)) {
    categoryPages.add(source.categoryData!.key);
  }
  if (source.favoriteData != null &&
      !networkFavorites.contains(source.favoriteData!.key)) {
    networkFavorites.add(source.favoriteData!.key);
  }
  if (source.searchPageData != null && !searchPages.contains(source.key)) {
    searchPages.add(source.key);
  }

  appdata.settings['explore_pages'] = explorePages.toSet().toList();
  appdata.settings['categories'] = categoryPages.toSet().toList();
  appdata.settings['favorites'] = networkFavorites.toSet().toList();
  appdata.settings['searchSources'] = searchPages.toSet().toList();

  appdata.saveData();
}

class _EditFilePage extends StatefulWidget {
  const _EditFilePage(this.path, this.onExit);

  final String path;

  final void Function() onExit;

  @override
  State<_EditFilePage> createState() => __EditFilePageState();
}

class __EditFilePageState extends State<_EditFilePage> {
  var current = '';

  @override
  void initState() {
    super.initState();
    current = File(widget.path).readAsStringSync();
  }

  @override
  void dispose() {
    File(widget.path).writeAsStringSync(current);
    widget.onExit();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(title: Text("Edit".tl)),
      body: Column(
        children: [
          Container(height: 0.6, color: context.colorScheme.outlineVariant),
          Expanded(
            child: CodeEditor(
              initialValue: current,
              onChanged: (value) => current = value,
            ),
          ),
        ],
      ),
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

  void check() async {
    setState(() {
      isLoading = true;
    });
    var count = await ComicSourcePage.checkComicSourceUpdate();
    if (count == -1) {
      context.showMessage(message: "Network error".tl);
    } else if (count == 0) {
      context.showMessage(message: "No updates".tl);
    } else {
      showUpdateDialog();
    }
    setState(() {
      isLoading = false;
    });
  }

  void showUpdateDialog() async {
    var text = ComicSourceManager().availableUpdates.entries
        .map((e) {
          return "${ComicSource.find(e.key)!.name}: ${e.value}";
        })
        .join("\n");
    bool doUpdate = false;
    await showDialog(
      context: App.rootContext,
      builder: (context) {
        return ContentDialog(
          title: "Updates".tl,
          content: Text(text).paddingHorizontal(16),
          actions: [
            FilledButton(
              onPressed: () {
                doUpdate = true;
                context.pop();
              },
              child: Text("Update".tl),
            ),
          ],
        );
      },
    );
    if (doUpdate) {
      var loadingController = showLoadingDialog(
        context,
        message: "Updating".tl,
        withProgress: true,
      );
      int current = 0;
      int total = ComicSourceManager().availableUpdates.length;
      try {
        var shouldUpdate = ComicSourceManager().availableUpdates.keys.toList();
        for (var key in shouldUpdate) {
          var source = ComicSource.find(key)!;
          await ComicSourcePage.update(source, false);
          current++;
          loadingController.setProgress(current / total);
        }
      } catch (e) {
        context.showMessage(message: e.toString());
      }
      loadingController.close();
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
      onPressed: check,
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

  @override
  Widget build(BuildContext context) {
    var newVersion = ComicSourceManager().availableUpdates[source.key];
    bool hasUpdate =
        newVersion != null && compareSemVer(newVersion, source.version);

    return SliverMainAxisGroup(
      slivers: [
        SliverPadding(padding: const EdgeInsets.only(top: 16)),
        SliverToBoxAdapter(
          child: ListTile(
            title: Row(
              children: [
                Text(source.name, style: ts.s18),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: context.colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    source.version,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                if (hasUpdate)
                  Tooltip(
                    message: newVersion,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: context.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        "New Version".tl,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ).paddingLeft(4),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Tooltip(
                  message: "Edit".tl,
                  child: IconButton(
                    onPressed: () => widget.edit(source),
                    icon: const Icon(Icons.edit_note),
                  ),
                ),
                Tooltip(
                  message: "Update".tl,
                  child: IconButton(
                    onPressed: () => widget.update(source),
                    icon: const Icon(Icons.update),
                  ),
                ),
                Tooltip(
                  message: "Delete".tl,
                  child: IconButton(
                    onPressed: () => widget.delete(source),
                    icon: const Icon(Icons.delete),
                  ),
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: context.colorScheme.outlineVariant,
                  width: 0.6,
                ),
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Column(children: buildSourceSettings().toList()),
        ),
        SliverToBoxAdapter(child: Column(children: _buildAccount().toList())),
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
