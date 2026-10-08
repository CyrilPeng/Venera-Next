import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/components/scroll.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/settings/logs.dart';
import 'package:venera_next/features/settings/debug_evaluator.dart';
import 'package:venera_next/features/settings/debug_evaluator_runtime.dart';
import 'package:venera_next/features/settings/setting_components.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

void _reportDebugFailure(Object error, StackTrace stack) {
  try {
    Log.error('JS Evaluator', error, stack);
  } catch (_) {
    // Logging is best effort; the operation still retains its original failure.
  }
}

class DebugPage extends StatefulWidget {
  const DebugPage({super.key, this.evaluate});
  final FutureOr<Object?> Function(String code)? evaluate;

  @override
  State<DebugPage> createState() => DebugPageState();
}

class DebugPageState extends State<DebugPage> {
  final controller = TextEditingController();

  var result = "";
  bool running = false;
  bool reloading = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> run() async {
    if (running) return;
    setState(() {
      running = true;
      result = 'Loading'.tl;
    });
    try {
      final evaluate = widget.evaluate;
      final evaluator = evaluate == null
          ? createDebugEvaluator(JsEngine())
          : DebugEvaluator(
              evaluate: evaluate,
              release: discardJsResult,
              drain: drainJsResultDescendants,
            );
      final operation = evaluator.start(controller.text);
      unawaited(
        operation.completion.then<void>((_) {}, onError: _reportDebugFailure),
      );
      final output = await operation.result;
      if (mounted) setState(() => result = output);
    } catch (error) {
      if (mounted) setState(() => result = error.toString());
    } finally {
      if (mounted) setState(() => running = false);
    }
  }

  Future<void> reload() async {
    if (reloading) return;
    setState(() => reloading = true);
    try {
      await ComicSourceManager().reloadForDebug();
      if (mounted) setState(() => result = 'Source reloaded'.tl);
    } catch (error) {
      if (mounted) setState(() => result = error.toString());
    } finally {
      if (mounted) setState(() => reloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("Debug".tl)),
        CallbackSetting(
          title: "Reload Configs".tl,
          actionTitle: "Reload".tl,
          callback: reload,
        ).toSliver(),
        CallbackSetting(
          title: "Open Log".tl,
          callback: () {
            context.to(() => const LogsPage());
          },
          actionTitle: 'Open'.tl,
        ).toSliver(),
        SwitchSetting.preference(
          title: "Ignore Certificate Errors".tl,
          preference: NetworkPreferences.ignoreBadCertificate,
        ).toSliver(),
        SliverToBoxAdapter(
          child: Column(
            children: [
              const SizedBox(height: 8),
              const Text(
                "JS Evaluator",
                style: TextStyle(fontSize: 16),
              ).toAlign(Alignment.centerLeft).paddingLeft(16),
              Container(
                width: double.infinity,
                height: 200,
                margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                child: TextField(
                  controller: controller,
                  maxLines: null,
                  expands: true,
                  textAlign: TextAlign.start,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    contentPadding: const EdgeInsets.all(8),
                  ),
                ),
              ),
              TextButton(
                onPressed: running ? null : run,
                child: Text(running ? 'Loading'.tl : 'Run'.tl),
              ).toAlign(Alignment.centerRight).paddingRight(16),
              const Text(
                "Result",
                style: TextStyle(fontSize: 16),
              ).toAlign(Alignment.centerLeft).paddingLeft(16),
              Container(
                width: double.infinity,
                height: 200,
                margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                decoration: BoxDecoration(
                  border: Border.all(color: context.colorScheme.outline),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(result).paddingAll(4),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
