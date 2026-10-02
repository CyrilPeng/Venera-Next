import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

import 'message.dart';

class JsUiApi implements JsUiMessageHandler {
  final _loadingDialogControllers =
      <
        int,
        ({LoadingDialogController controller, JsCallbackScope callbacks})
      >{};

  @override
  dynamic handleUIMessage(Map<String, dynamic> message) {
    switch (message['function']) {
      case 'showMessage':
        var m = message['message'];
        if (m.toString().isNotEmpty) {
          App.rootContext.showMessage(message: m.toString());
        }
      case 'showDialog':
        return _showDialog(message);
      case 'launchUrl':
        var url = message['url'];
        if (url.toString().isNotEmpty) {
          launchUrlString(url.toString());
        }
      case 'showLoading':
        var onCancel = message['onCancel'];
        if (onCancel != null && onCancel is! JSInvokable) {
          return;
        }
        return _showLoading(onCancel);
      case 'cancelLoading':
        var id = message['id'];
        if (id is int) {
          _cancelLoading(id);
        }
      case 'showInputDialog':
        var title = message['title'];
        var validator = message['validator'];
        var image = message['image'];
        if (title is! String) return;
        if (validator != null && validator is! JSInvokable) return;
        return _showInputDialog(title, validator, image);
      case 'showSelectDialog':
        var title = message['title'];
        var options = message['options'];
        var initialIndex = message['initialIndex'];
        if (title is! String) return;
        if (options is! List) return;
        if (initialIndex != null && initialIndex is! int) return;
        return _showSelectDialog(
          title,
          options.whereType<String>().toList(),
          initialIndex,
        );
    }
  }

  Future<void> _showDialog(Map<String, dynamic> message) async {
    final callbacks = JsCallbackScope();
    final disposed = Completer<void>();
    try {
      BuildContext? dialogContext;
      var title = message['title'];
      var content = message['content'];
      var actions = <Widget>[];
      for (var action in message['actions']) {
        if (action['callback'] is! JSInvokable) {
          continue;
        }
        var callback = action['callback'] as JSInvokable;
        var text = action['text'].toString();
        var style = (action['style'] ?? 'text').toString();
        actions.add(
          _JSCallbackButton(
            text: text,
            callback: callbacks.retain(callback),
            style: style,
            onCallbackFinished: () {
              dialogContext?.pop();
            },
          ),
        );
      }
      if (actions.isEmpty) {
        actions.add(
          TextButton(
            onPressed: () {
              dialogContext?.pop();
            },
            child: Text('OK'.tl),
          ),
        );
      }
      final closed =
          showDialog<void>(
            context: App.rootContext,
            builder: (context) {
              dialogContext = context;
              return DialogResourceScope(
                onDispose: () {
                  callbacks.dispose();
                  if (!disposed.isCompleted) disposed.complete();
                },
                child: ContentDialog(
                  title: title,
                  content: Text(content).paddingHorizontal(16),
                  actions: actions,
                ),
              );
            },
          ).then((value) {
            dialogContext = null;
          });
      await Future.any<void>([closed, disposed.future]);
    } finally {
      callbacks.dispose();
    }
  }

  int _showLoading(JSInvokable? onCancel) {
    final callbacks = JsCallbackScope();
    var id = 0;
    while (_loadingDialogControllers.containsKey(id)) {
      id++;
    }
    final loadingId = id;
    void release() {
      if (identical(
        _loadingDialogControllers[loadingId]?.callbacks,
        callbacks,
      )) {
        _loadingDialogControllers.remove(loadingId);
      }
      callbacks.dispose();
    }

    try {
      final cancel = onCancel == null ? null : callbacks.retain(onCancel);
      final controller = showLoadingDialog(
        App.rootContext,
        barrierDismissible: onCancel != null,
        allowCancel: onCancel != null,
        onCancel: cancel == null
            ? null
            : () {
                unawaited(
                  Future.sync(() => cancel([])).then<void>(
                    JSRef.freeRecursive,
                    onError: (Object error, StackTrace stack) =>
                        Log.error('JS loading cancellation', error, stack),
                  ),
                );
              },
        onClosed: release,
      );
      _loadingDialogControllers[id] = (
        controller: controller,
        callbacks: callbacks,
      );
      return id;
    } catch (_) {
      release();
      rethrow;
    }
  }

  void _cancelLoading(int id) {
    final entry = _loadingDialogControllers.remove(id);
    try {
      entry?.controller.close();
    } finally {
      entry?.callbacks.dispose();
    }
  }

  Future<String?> _showInputDialog(
    String title,
    JSInvokable? validator,
    dynamic image,
  ) async {
    final callbacks = JsCallbackScope();
    try {
      String? result;
      final func = validator == null ? null : callbacks.retain(validator);
      String? imageUrl;
      Uint8List? imageData;
      if (image != null) {
        if (image is String) {
          imageUrl = image;
        } else if (image is Uint8List) {
          imageData = image;
        } else if (image is List<int>) {
          imageData = Uint8List.fromList(image);
        }
      }
      await showInputDialog(
        context: App.rootContext,
        title: title,
        onClosed: callbacks.dispose,
        image: imageUrl,
        imageData: imageData,
        onConfirm: (v) {
          dynamic validation;
          try {
            validation = func?.call([v]);
            if (validation != null) return validation.toString();
            result = v;
            return null;
          } catch (error, stack) {
            Log.error('JS input validation', error, stack);
            return error.toString();
          } finally {
            JSRef.freeRecursive(validation);
          }
        },
      );
      return result;
    } finally {
      callbacks.dispose();
    }
  }

  Future<int?> _showSelectDialog(
    String title,
    List<String> options,
    int? initialIndex,
  ) {
    if (options.isEmpty) {
      return Future.value(null);
    }
    if (initialIndex != null &&
        (initialIndex >= options.length || initialIndex < 0)) {
      initialIndex = null;
    }
    return showSelectDialog(
      title: title,
      options: options,
      initialIndex: initialIndex,
    );
  }
}

class _JSCallbackButton extends StatefulWidget {
  const _JSCallbackButton({
    required this.text,
    required this.callback,
    required this.style,
    this.onCallbackFinished,
  });

  final dynamic Function(List<dynamic>) callback;

  final String text;

  final String style;

  final void Function()? onCallbackFinished;

  @override
  State<_JSCallbackButton> createState() => _JSCallbackButtonState();
}

class _JSCallbackButtonState extends State<_JSCallbackButton> {
  bool isLoading = false;

  void onClick() async {
    if (isLoading) {
      return;
    }
    dynamic result;
    try {
      result = widget.callback([]);
      if (result is Future) {
        setState(() => isLoading = true);
        result = await result;
      }
      if (mounted) widget.onCallbackFinished?.call();
    } catch (error, stack) {
      Log.error('JS dialog callback', error, stack);
      if (mounted) context.showMessage(message: error.toString());
    } finally {
      JSRef.freeRecursive(result);
      if (mounted && isLoading) setState(() => isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return switch (widget.style) {
      "filled" => FilledButton(
        onPressed: onClick,
        child: isLoading
            ? CircularProgressIndicator(
                strokeWidth: 1.4,
              ).fixWidth(18).fixHeight(18)
            : Text(widget.text),
      ),
      "danger" => FilledButton(
        onPressed: onClick,
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.all(context.colorScheme.error),
        ),
        child: isLoading
            ? CircularProgressIndicator(
                strokeWidth: 1.4,
              ).fixWidth(18).fixHeight(18)
            : Text(widget.text),
      ),
      _ => TextButton(
        onPressed: onClick,
        child: isLoading
            ? CircularProgressIndicator(
                strokeWidth: 1.4,
              ).fixWidth(18).fixHeight(18)
            : Text(widget.text),
      ),
    };
  }
}
