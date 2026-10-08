import 'dart:async';
import 'package:venera_next/foundation/application_preferences.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/components/scroll.dart';
import 'package:venera_next/features/settings/setting_components.dart';
import 'package:venera_next/features/settings/sponsors.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';
import 'package:venera_next/components/application_update_prompt.dart';

class AboutSettings extends StatefulWidget {
  const AboutSettings({super.key});

  @override
  State<AboutSettings> createState() => _AboutSettingsState();
}

class _AboutSettingsState extends State<AboutSettings> {
  ApplicationUpdatePrompt? _checking;
  bool _checkingNetwork = false;

  Future<void> _checkUpdate() async {
    if (_checking != null) return;
    final prompt = ApplicationUpdatePrompt(
      context: context,
      service: ApplicationUpdateScope.of(context),
    );
    setState(() {
      _checking = prompt;
      _checkingNetwork = true;
    });
    try {
      await prompt.check(
        onChecked: () {
          if (mounted && identical(_checking, prompt)) {
            setState(() => _checkingNetwork = false);
          }
        },
      );
    } finally {
      if (mounted && identical(_checking, prompt)) {
        setState(() {
          _checking = null;
          _checkingNetwork = false;
        });
      }
    }
  }

  @override
  void dispose() {
    unawaited(_checking?.closeAndWait());
    super.dispose();
  }

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
          trailing: FilledButton(
            onPressed: _checking == null ? _checkUpdate : null,
            child: _checkingNetwork
                ? SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      semanticsLabel: 'Check for updates'.tl,
                    ),
                  )
                : Text('Check'.tl),
          ),
        ).toSliver(),
        ListTile(
          title: Text("Changelog".tl),
          trailing: const Icon(Icons.keyboard_arrow_right),
          onTap: () {
            context.to(() => const ChangelogPage());
          },
        ).toSliver(),
        SwitchSetting.preference(
          title: "Check for updates on startup".tl,
          preference: AppPreferences.checkUpdateOnStart,
        ).toSliver(),
        ListTile(
          title: const Text("Github"),
          trailing: const Icon(Icons.open_in_new),
          onTap: () {
            launchUrlString("https://github.com/CyrilPeng/venera-next");
          },
        ).toSliver(),
        ListTile(
          title: Text("Sponsors".tl),
          trailing: const Icon(Icons.keyboard_arrow_right),
          onTap: () {
            context.to(() => const SponsorsPage());
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
