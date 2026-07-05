import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/scroll.dart';
import 'package:venera_next/features/settings/setting_components.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/network/app_dio.dart';
import 'package:yaml/yaml.dart';

class AboutSettings extends StatefulWidget {
  const AboutSettings({super.key});

  @override
  State<AboutSettings> createState() => _AboutSettingsState();
}

class _AboutSettingsState extends State<AboutSettings> {
  bool isCheckingUpdate = false;

  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("About".tl)),
        SizedBox(
          height: 112,
          width: double.infinity,
          child: Center(
            child: Container(
              width: 112,
              height: 112,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(136),
              ),
              clipBehavior: Clip.antiAlias,
              child: const Image(
                image: AssetImage("assets/app_icon.png"),
                filterQuality: FilterQuality.medium,
              ),
            ),
          ),
        ).paddingTop(16).toSliver(),
        Column(
          children: [
            const SizedBox(height: 8),
            Text("V${App.version}", style: const TextStyle(fontSize: 16)),
            Text(
              "VeneraNext is a free and open-source app for comic reading.".tl,
            ),
            const SizedBox(height: 8),
          ],
        ).toSliver(),
        ListTile(
          title: Text("Check for updates".tl),
          trailing: Button.filled(
            isLoading: isCheckingUpdate,
            child: Text("Check".tl),
            onPressed: () {
              setState(() {
                isCheckingUpdate = true;
              });
              checkUpdateUi().then((value) {
                setState(() {
                  isCheckingUpdate = false;
                });
              });
            },
          ).fixHeight(32),
        ).toSliver(),
        ListTile(
          title: Text("Changelog".tl),
          trailing: const Icon(Icons.keyboard_arrow_right),
          onTap: () {
            context.to(() => const ChangelogPage());
          },
        ).toSliver(),
        SwitchSetting(
          title: "Check for updates on startup".tl,
          settingKey: "checkUpdateOnStart",
        ).toSliver(),
        ListTile(
          title: const Text("Github"),
          trailing: const Icon(Icons.open_in_new),
          onTap: () {
            launchUrlString("https://github.com/CyrilPeng/venera-next");
          },
        ).toSliver(),
      ],
    );
  }
}

class ChangelogPage extends StatefulWidget {
  const ChangelogPage({super.key});

  @override
  State<ChangelogPage> createState() => _ChangelogPageState();
}

class _ChangelogPageState extends State<ChangelogPage> {
  late final Future<String> _changelog = rootBundle.loadString("CHANGELOG.md");

  @override
  Widget build(BuildContext context) {
    return Material(
      child: SmoothCustomScrollView(
        slivers: [
          SliverAppbar(title: Text("Changelog".tl)),
          FutureBuilder(
            future: _changelog,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: Text("Error".tl)),
                );
              }
              if (!snapshot.hasData) {
                return const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              return SelectionArea(
                child: _ChangelogMarkdown(snapshot.data!),
              ).paddingAll(16).toSliver();
            },
          ),
        ],
      ),
    );
  }
}

class _ChangelogMarkdown extends StatelessWidget {
  const _ChangelogMarkdown(this.data);

  final String data;

  @override
  Widget build(BuildContext context) {
    final lines = data.split(RegExp(r'\r?\n'));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final line in lines) _ChangelogMarkdownBlock(line)],
    );
  }
}

class _ChangelogMarkdownBlock extends StatelessWidget {
  const _ChangelogMarkdownBlock(this.line);

  final String line;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final trimmed = line.trimRight();
    if (trimmed.isEmpty) {
      return const SizedBox(height: 8);
    }
    if (trimmed.startsWith('### ')) {
      return _blockText(
        context,
        trimmed.substring(4),
        theme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        top: 14,
        bottom: 4,
      );
    }
    if (trimmed.startsWith('## ')) {
      return _blockText(
        context,
        trimmed.substring(3),
        theme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        top: 20,
        bottom: 6,
      );
    }
    if (trimmed.startsWith('# ')) {
      return _blockText(
        context,
        trimmed.substring(2),
        theme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        bottom: 8,
      );
    }
    if (trimmed.startsWith('- ')) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '•',
              style: theme.bodyMedium?.copyWith(
                color: colorScheme.primary,
                height: 1.35,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text.rich(
                TextSpan(
                  style: theme.bodyMedium?.copyWith(height: 1.35),
                  children: _inlineSpans(context, trimmed.substring(2)),
                ),
              ),
            ),
          ],
        ),
      );
    }
    return _blockText(
      context,
      trimmed,
      theme.bodyMedium?.copyWith(height: 1.35),
      bottom: 6,
    );
  }

  Widget _blockText(
    BuildContext context,
    String text,
    TextStyle? style, {
    double top = 0,
    double bottom = 0,
  }) {
    return Padding(
      padding: EdgeInsets.only(top: top, bottom: bottom),
      child: Text.rich(
        TextSpan(style: style, children: _inlineSpans(context, text)),
      ),
    );
  }

  List<TextSpan> _inlineSpans(BuildContext context, String text) {
    final spans = <TextSpan>[];
    final colorScheme = Theme.of(context).colorScheme;
    final baseStyle = DefaultTextStyle.of(context).style;
    var index = 0;
    while (index < text.length) {
      final start = text.indexOf('`', index);
      if (start == -1) {
        spans.add(TextSpan(text: text.substring(index)));
        break;
      }
      final end = text.indexOf('`', start + 1);
      if (end == -1) {
        spans.add(TextSpan(text: text.substring(index)));
        break;
      }
      if (start > index) {
        spans.add(TextSpan(text: text.substring(index, start)));
      }
      spans.add(
        TextSpan(
          text: text.substring(start + 1, end),
          style: baseStyle.copyWith(
            fontFamily: 'monospace',
            color: colorScheme.onSecondaryContainer,
            backgroundColor: colorScheme.secondaryContainer,
          ),
        ),
      );
      index = end + 1;
    }
    return spans;
  }
}

Future<String?> checkUpdate() async {
  var versions = await Future.wait([
    _fetchUpdateVersion(_fetchPubspecVersion, "Update Pubspec"),
    _fetchUpdateVersion(_fetchLatestReleaseVersion, "Latest Release"),
  ]);
  var remoteVersion = selectUpdateVersionForTesting(versions, App.version);
  if (remoteVersion == null) return null;
  return shouldNotifyUpdateForTesting(remoteVersion, App.version)
      ? remoteVersion
      : null;
}

Future<String?> _fetchUpdateVersion(
  Future<String?> Function() fetcher,
  String source,
) async {
  try {
    return await fetcher();
  } catch (e, s) {
    Log.error("Check Update", "$source: $e", s);
    return null;
  }
}

Future<String?> _fetchLatestReleaseVersion() async {
  var res = await AppDio().get(
    "https://api.github.com/repos/CyrilPeng/venera-next/releases/latest",
  );
  if (res.statusCode == 200) {
    var data = res.data is String ? jsonDecode(res.data) : res.data;
    var tag = data["tag_name"]?.toString();
    if (tag != null) {
      return tag.startsWith('v') ? tag.substring(1) : tag;
    }
  }
  return null;
}

Future<String?> _fetchPubspecVersion() async {
  var res = await AppDio().get(
    "https://cdn.jsdelivr.net/gh/CyrilPeng/venera-next@main/pubspec.yaml",
  );
  if (res.statusCode == 200) {
    var data = loadYaml(res.data);
    if (data["version"] != null) {
      return data["version"].toString().split('+').first;
    }
  }
  return null;
}

Future<void> checkUpdateUi([
  bool showMessageIfNoUpdate = true,
  bool delay = false,
]) async {
  try {
    var newVersion = await checkUpdate();
    if (newVersion != null) {
      if (delay) {
        await Future.delayed(const Duration(seconds: 2));
      }
      if (!App.rootContext.mounted) return;
      showDialog(
        context: App.rootContext,
        builder: (context) {
          return ContentDialog(
            title: "New version available".tl,
            content: Text(
              "A new version @v is available. Do you want to update now?"
                  .tlParams({"v": newVersion}),
            ).paddingHorizontal(16),
            actions: [
              Button.text(
                onPressed: () {
                  Navigator.pop(context);
                  launchUrlString(
                    "https://github.com/CyrilPeng/venera-next/releases",
                  );
                },
                child: Text("Update".tl),
              ),
            ],
          );
        },
      );
    } else if (showMessageIfNoUpdate) {
      if (!App.rootContext.mounted) return;
      App.rootContext.showMessage(message: "No new version available".tl);
    }
  } catch (e, s) {
    Log.error("Check Update", e.toString(), s);
    if (showMessageIfNoUpdate) {
      if (!App.rootContext.mounted) return;
      App.rootContext.showMessage(message: "Failed to check for updates".tl);
    }
  }
}

/// return true if version1 > version2
bool _compareVersion(String version1, String version2) {
  var v1 = _versionNumbers(version1);
  var v2 = _versionNumbers(version2);
  final length = v1.length > v2.length ? v1.length : v2.length;
  for (var i = 0; i < length; i++) {
    var n1 = i < v1.length ? v1[i] : 0;
    var n2 = i < v2.length ? v2[i] : 0;
    if (n1 > n2) return true;
    if (n1 < n2) return false;
  }
  return _comparePrerelease(_prerelease(version1), _prerelease(version2));
}

@visibleForTesting
String? selectUpdateVersionForTesting(
  Iterable<String?> versions,
  String currentVersion,
) {
  return versions
      .whereType<String>()
      .where((version) => _canNotifyChannel(version, currentVersion))
      .fold<String?>(null, (max, version) {
        if (max == null) return version;
        return _compareVersion(version, max) ? version : max;
      });
}

@visibleForTesting
bool shouldNotifyUpdateForTesting(String remoteVersion, String currentVersion) {
  return _canNotifyChannel(remoteVersion, currentVersion) &&
      _compareVersion(remoteVersion, currentVersion);
}

bool _canNotifyChannel(String remoteVersion, String currentVersion) {
  return !_isPrerelease(remoteVersion) || _isPrerelease(currentVersion);
}

bool _isPrerelease(String version) => _prerelease(version) != null;

String _versionCore(String version) {
  return version.trim().replaceFirst(RegExp(r'^[vV]'), '').split('+').first;
}

List<int> _versionNumbers(String version) {
  return _versionCore(version)
      .split('-')
      .first
      .split('.')
      .map((segment) => int.tryParse(segment) ?? 0)
      .toList();
}

String? _prerelease(String version) {
  var core = _versionCore(version);
  var index = core.indexOf('-');
  return index == -1 ? null : core.substring(index + 1);
}

bool _comparePrerelease(String? version1, String? version2) {
  if (version1 == null || version2 == null) {
    return version1 == null && version2 != null;
  }

  var parts1 = version1.split('.');
  var parts2 = version2.split('.');
  final length = parts1.length > parts2.length ? parts1.length : parts2.length;
  for (var i = 0; i < length; i++) {
    if (i >= parts1.length) return false;
    if (i >= parts2.length) return true;

    var part1 = parts1[i];
    var part2 = parts2[i];
    var num1 = int.tryParse(part1);
    var num2 = int.tryParse(part2);
    if (num1 != null && num2 != null) {
      if (num1 > num2) return true;
      if (num1 < num2) return false;
    } else if (num1 != null) {
      return false;
    } else if (num2 != null) {
      return true;
    } else {
      var comparison = part1.compareTo(part2);
      if (comparison > 0) return true;
      if (comparison < 0) return false;
    }
  }
  return false;
}
