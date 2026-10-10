import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/foundation/translations.dart';

import 'comic_copy_record.dart';

typedef ComicCopyRecoveryChoice = ({String? folder});

Future<ComicCopyRecoveryChoice?> showComicCopyRecoveryDialog({
  required BuildContext context,
  required String title,
  required String? previousFolder,
  required List<String> folders,
  ComicCopyRecoveryKind kind = ComicCopyRecoveryKind.complete,
  required VoidCallback Function(VoidCallback close, bool Function() isCurrent)
  retainPresentation,
}) async {
  final disposed = Completer<ComicCopyRecoveryChoice?>();
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<ComicCopyRecoveryChoice>(
    context: context,
    animationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : null,
    builder: (context) => DialogResourceScope(
      onDispose: () {
        if (!disposed.isCompleted) disposed.complete();
      },
      child: ComicCopyRecoveryDialog(
        title: title,
        previousFolder: previousFolder,
        folders: folders,
        kind: kind,
      ),
    ),
  );
  final closed = navigator.push(route);
  final detach = retainPresentation(() {
    if (navigator.mounted && route.isActive) navigator.removeRoute(route);
  }, () => route.isCurrent);
  try {
    return await Future.any([closed, disposed.future]);
  } finally {
    detach();
  }
}

class ComicCopyRecoveryDialog extends StatefulWidget {
  const ComicCopyRecoveryDialog({
    super.key,
    required this.title,
    required this.previousFolder,
    required this.folders,
    this.kind = ComicCopyRecoveryKind.complete,
  });
  final String title;
  final String? previousFolder;
  final List<String> folders;
  final ComicCopyRecoveryKind kind;
  @override
  State<ComicCopyRecoveryDialog> createState() =>
      _ComicCopyRecoveryDialogState();
}

class _ComicCopyRecoveryDialogState extends State<ComicCopyRecoveryDialog> {
  int? _selected;
  bool _submitted = false;

  void _finish(ComicCopyRecoveryChoice? choice) {
    if (_submitted || ModalRoute.of(context)?.isCurrent != true) return;
    _submitted = true;
    Navigator.of(context).pop(choice);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text('Recover comic'.tl),
    content: SizedBox(
      width: 440,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Text(switch (widget.kind) {
            ComicCopyRecoveryKind.complete =>
              'The copy is complete. Choose where to restore it. Its previous favorite folder was @a.'
                  .tlParams({
                    'a': widget.previousFolder ?? 'Local library only'.tl,
                  }),
            ComicCopyRecoveryKind.resumable =>
              'This copy was interrupted. Restore will copy the missing files from the unchanged source, then add the comic to your library.'
                  .tl,
            ComicCopyRecoveryKind.unverified =>
              'This directory has no completion record. Pages may be missing. Restore will add only the files currently available; check them before continuing.'
                  .tl,
          }),
          const SizedBox(height: 12),
          RadioGroup<int>(
            groupValue: _selected,
            onChanged: (value) => setState(() => _selected = value),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<int>(
                  value: 0,
                  autofocus: true,
                  title: Text('Local library only'.tl),
                  contentPadding: EdgeInsets.zero,
                ),
                for (var i = 0; i < widget.folders.length; i++)
                  RadioListTile<int>(
                    value: i + 1,
                    title: Text(widget.folders[i]),
                    contentPadding: EdgeInsets.zero,
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => _finish(null), child: Text('Later'.tl)),
      FilledButton(
        onPressed: _selected == null
            ? null
            : () => _finish((
                folder: _selected == 0 ? null : widget.folders[_selected! - 1],
              )),
        child: Text('Restore'.tl),
      ),
    ],
  );
}
