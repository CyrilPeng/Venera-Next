import 'dart:async';
import 'package:flutter/material.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/network/request_scope.dart';
import 'favorite_models.dart';
import 'network_favorite_import.dart';

class NetworkFavoriteImportDialog extends StatefulWidget {
  const NetworkFavoriteImportDialog({
    super.key,
    required this.collect,
    required this.commit,
    required this.publish,
  });
  final Future<List<FavoriteItem>> Function(
    RequestScope,
    void Function(FavoriteImportProgress),
  )
  collect;
  final FutureOr<NetworkFavoriteImportCommit> Function(
    List<FavoriteItem>,
    RequestScope,
  )
  commit;
  final FutureOr<void> Function(NetworkFavoriteImportCommit) publish;
  @override
  State<NetworkFavoriteImportDialog> createState() =>
      _NetworkFavoriteImportDialogState();
}

class _NetworkFavoriteImportDialogState
    extends State<NetworkFavoriteImportDialog> {
  final scope = RequestScope();
  FavoriteImportProgress progress = (pages: 0, received: 0, collected: 0);
  String? error;
  NetworkFavoriteImportCommit? committed;
  String? publicationError;
  bool publishing = false;
  @override
  void initState() {
    super.initState();
    run();
  }

  Future<void> run() async {
    try {
      final items = await widget.collect(scope, (value) {
        if (mounted && !scope.isCancelled) setState(() => progress = value);
      });
      scope.check();
      if (!mounted) return;
      final result = await widget.commit(items, scope);
      if (mounted) setState(() => committed = result);
      // SQL has committed. Publication errors cannot change this outcome.
      await publish(result);
    } catch (failure) {
      if (mounted && !scope.isCancelled) {
        setState(() => error = failure.toString());
      }
    }
  }

  Future<void> publish(NetworkFavoriteImportCommit result) async {
    if (publishing) return;
    publishing = true;
    if (mounted) setState(() {});
    String? failure;
    try {
      await widget.publish(result);
    } catch (error, stack) {
      Log.error('Favorite import publication', error, stack);
      failure = error.toString();
    }
    publishing = false;
    if (mounted && !scope.isCancelled) {
      setState(() => publicationError = failure);
    }
  }

  @override
  void dispose() {
    scope.cancel();
    scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    onPopInvokedWithResult: (didPop, result) {
      if (didPop) scope.cancel();
    },
    child: ContentDialog(
      title: committed != null
          ? 'Finished'.tl
          : error != null
          ? 'Error'.tl
          : 'Importing'.tl,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(
            value: committed != null
                ? 1
                : error != null
                ? 0
                : null,
          ),
          Text(
            'Imported @a comics, loaded @b pages, received @c comics'.tlParams({
              'a': committed?.count ?? 0,
              'b': progress.pages,
              'c': progress.received,
            }),
          ),
          if (error != null) Text(error!),
          if (publicationError != null)
            Text("${'Refresh'.tl}: $publicationError"),
        ],
      ),
      actions: [
        if (publicationError != null && committed != null)
          Button.text(
            isLoading: publishing,
            onPressed: () => publish(committed!),
            child: Text('Refresh'.tl),
          ),
        Button.filled(
          onPressed: () {
            scope.cancel();
            context.pop();
          },
          child: Text(
            committed != null || error != null ? 'OK'.tl : 'Cancel'.tl,
          ),
        ),
      ],
    ),
  );
}
