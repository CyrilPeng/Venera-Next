import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera_next/components/input_dialog.dart';
import 'package:venera_next/components/select_dialog.dart';
import 'package:venera_next/routing/app_navigation.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

import 'message.dart';
import 'window_selection_task.dart';

class JsUiApi implements JsUiMessageHandler {
  final _loadingDialogControllers = <int, _JsLoadingPresentation>{};
  WindowSelectionTask? _owner;

  BuildContext get _context {
    final owner = _owner;
    if (owner != null) {
      return owner.presentationContext ??
          (throw JsDisposedError('JavaScript UI host is closed'));
    }
    final context = appNavigation.rootNavigatorKey.currentContext;
    if (context == null) {
      throw JsDisposedError('JavaScript UI host is not mounted');
    }
    final acquired = WindowSelectionTask(context);
    acquired.checkActive();
    _owner = acquired;
    return context;
  }

  @override
  dynamic handleUIMessage(
    Map<String, dynamic> message, {
    required JsEngine engine,
  }) {
    switch (message['function']) {
      case 'showMessage':
        var m = message['message'];
        if (m.toString().isNotEmpty) {
          _context.showMessage(message: m.toString());
        }
      case 'showDialog':
        return _showDialog(message, engine);
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
        return _showLoading(onCancel, engine);
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
        return _showInputDialog(title, validator, image, engine);
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

  Future<void> _showDialog(
    Map<String, dynamic> message,
    JsEngine engine,
  ) async {
    final context = _context;
    final task = WindowSelectionTask(context);
    final navigator = Navigator.of(context, rootNavigator: true);
    final callbacks = JsCallbackScope(engine: engine);
    final disposed = Completer<void>();
    final removalFailed = Completer<void>();
    removalFailed.future.ignore();
    try {
      ResourceDialogRoute<void>? route;
      bool canAct() => task.canPresent && route?.isCurrent == true;
      void finish() {
        if (canAct()) navigator.pop();
      }

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
            canAct: canAct,
            onCallbackFinished: finish,
          ),
        );
      }
      if (actions.isEmpty) {
        actions.add(TextButton(onPressed: finish, child: Text('OK'.tl)));
      }
      await task.run((operation) async {
        operation.checkActive();
        final dialog = route = ResourceDialogRoute<void>(
          context: context,
          onDispose: () {
            if (!disposed.isCompleted) disposed.complete();
          },
          builder: (_) => ContentDialog(
            title: title,
            content: Text(content).paddingHorizontal(16),
            actions: actions,
          ),
        );
        final release = task.retainPresentation(() {
          try {
            if (navigator.mounted && dialog.isActive) {
              navigator.removeRoute(dialog);
            } else if (!disposed.isCompleted) {
              disposed.complete();
            }
          } catch (error, stack) {
            if (!removalFailed.isCompleted) {
              removalFailed.completeError(error, stack);
            }
            rethrow;
          }
        }, isCurrent: () => dialog.isCurrent);
        try {
          final closed = navigator.push(dialog).then<void>((_) {});
          await Future.any<void>([
            closed,
            disposed.future,
            removalFailed.future,
          ]);
        } finally {
          if (!navigator.mounted || !dialog.isActive) release();
          callbacks.dispose();
        }
      });
    } on SelectionCancelled {
      // Admission can close between accepting the message and pushing its UI.
    } finally {
      callbacks.dispose();
    }
  }

  int _showLoading(JSInvokable? onCancel, JsEngine engine) {
    final context = _context;
    final callbacks = JsCallbackScope(engine: engine);
    var id = 0;
    while (_loadingDialogControllers.containsKey(id)) {
      id++;
    }
    final loadingId = id;
    late final _JsLoadingPresentation entry;
    void release() {
      if (identical(_loadingDialogControllers[loadingId], entry)) {
        _loadingDialogControllers.remove(loadingId);
      }
    }

    try {
      final cancel = onCancel == null ? null : callbacks.retain(onCancel);
      entry = _JsLoadingPresentation(
        context: context,
        callbacks: callbacks,
        cancel: cancel,
        release: release,
      );
      _loadingDialogControllers[id] = entry;
      entry.start();
      return id;
    } catch (_) {
      callbacks.dispose();
      rethrow;
    }
  }

  void _cancelLoading(int id) {
    final entry = _loadingDialogControllers.remove(id);
    entry?.finish();
  }

  Future<String?> _showInputDialog(
    String title,
    JSInvokable? validator,
    dynamic image,
    JsEngine engine,
  ) async {
    final context = _context;
    final callbacks = JsCallbackScope(engine: engine);
    final task = WindowSelectionTask(context);
    final presentation = Completer<String?>();
    final pending = <Future<void>>{};
    try {
      String? result;
      final func = validator == null
          ? null
          : callbacks.retainImmediate(validator);
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
      final work = task.run((operation) async {
        operation.checkActive();
        try {
          await showInputDialog(
            context: context,
            title: title,
            onClosed: callbacks.dispose,
            image: imageUrl,
            imageData: imageData,
            onConfirm: (value) {
              String? validation = 'Error'.tl;
              var reported = false;
              void describe(Object error, StackTrace stack) {
                reported = true;
                Log.error('JS input validation', error, stack);
                validation = error.toString();
              }

              try {
                final completion = func?.call([value], (immediate, stack) {
                  try {
                    if (stack != null) {
                      describe(immediate as Object, stack);
                    } else {
                      validation = immediate?.toString();
                    }
                  } catch (error, stack) {
                    describe(error, stack);
                  }
                });
                if (completion == null) {
                  validation = null;
                } else {
                  late final Future<void> observed;
                  observed = completion
                      .then<void>(
                        (_) {},
                        onError: (Object error, StackTrace stack) {
                          if (error is JsDisposedError) return;
                          if (!reported || error is JsResourceReleaseFailure) {
                            Log.error('JS input validation', error, stack);
                          }
                        },
                      )
                      .whenComplete(() => pending.remove(observed));
                  pending.add(observed);
                  observed.ignore();
                }
              } catch (error, stack) {
                describe(error, stack);
              }
              if (validation == null) result = value;
              return validation;
            },
          );
          presentation.complete(result);
        } catch (error, stack) {
          presentation.completeError(error, stack);
          rethrow;
        } finally {
          try {
            callbacks.dispose();
          } finally {
            // Display completion remains independent of ignored validator
            // Promises. Their original application keeps this registration.
            await Future.wait(pending.toList());
          }
        }
      });
      unawaited(
        work.then<void>(
          (_) {},
          onError: (Object error, StackTrace stack) {
            try {
              callbacks.dispose();
            } catch (cleanup, cleanupStack) {
              Log.error('JS input callback release', cleanup, cleanupStack);
            }
            if (!presentation.isCompleted) {
              if (error is SelectionCancelled || error is JsDisposedError) {
                presentation.complete(null);
              } else {
                presentation.completeError(error, stack);
              }
            } else if (error is! SelectionCancelled &&
                error is! JsDisposedError) {
              Log.error('JS input presentation', error, stack);
            }
          },
        ),
      );
      return presentation.future;
    } catch (_) {
      callbacks.dispose();
      rethrow;
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
      context: _context,
      title: title,
      options: options,
      initialIndex: initialIndex,
    );
  }
}

class _JsLoadingPresentation {
  _JsLoadingPresentation({
    required this.context,
    required this.callbacks,
    required this.cancel,
    required this.release,
  }) : task = WindowSelectionTask(context);

  final BuildContext context;
  final JsCallbackScope callbacks;
  final JsCallback? cancel;
  final VoidCallback release;
  final WindowSelectionTask task;
  final _closed = Completer<void>();
  Future<void>? _cancellation;
  bool _cancelStarted = false;
  bool _finished = false;

  void _cancel() {
    final callback = cancel;
    if (callback == null || _cancelStarted || _finished) return;
    _cancelStarted = true;
    _cancellation = invokeJsCallbackToCompletion(callback, []);
    // Observe an early rejection while the route is still closing. The task
    // below awaits the original Future and retains its error.
    _cancellation!.ignore();
  }

  void _releaseDisplay() {
    release();
    if (!_closed.isCompleted) _closed.complete();
  }

  void finish() {
    _finished = true;
    task.cancel();
  }

  void start() {
    final removalFailed = Completer<void>();
    removalFailed.future.ignore();
    unawaited(
      task
          .run((operation) async {
            operation.checkActive();
            final controller = showLoadingDialog(
              context,
              barrierDismissible: cancel != null,
              allowCancel: cancel != null,
              onCancel: _cancel,
              onClosed: _releaseDisplay,
            );
            final releasePresentation = task.retainPresentation(() {
              try {
                _cancel();
                controller.close();
              } catch (error, stack) {
                if (!removalFailed.isCompleted) {
                  removalFailed.completeError(error, stack);
                }
                rethrow;
              }
            }, isCurrent: () => controller.isCurrent);
            try {
              await Future.any<void>([_closed.future, removalFailed.future]);
            } finally {
              try {
                // A failed display removal must not finish an already
                // accepted cancellation before its actual invocation ends.
                await _cancellation;
              } finally {
                if (controller.closed) releasePresentation();
                callbacks.dispose();
              }
            }
          })
          .whenComplete(() {
            release();
            callbacks.dispose();
          })
          .catchError((Object error, StackTrace stack) {
            if (error is SelectionCancelled || error is JsDisposedError) return;
            Log.error('JS loading cancellation', error, stack);
          }),
    );
  }
}

class _JSCallbackButton extends StatefulWidget {
  const _JSCallbackButton({
    required this.text,
    required this.callback,
    required this.style,
    required this.canAct,
    this.onCallbackFinished,
  });

  final dynamic Function(List<dynamic>) callback;

  final String text;

  final String style;

  final bool Function() canAct;

  final void Function()? onCallbackFinished;

  @override
  State<_JSCallbackButton> createState() => _JSCallbackButtonState();
}

class _JSCallbackButtonState extends State<_JSCallbackButton> {
  bool isLoading = false;
  WindowSelectionTask? _task;

  @override
  void dispose() {
    _task?.cancel();
    super.dispose();
  }

  void onClick() async {
    if (isLoading || !mounted || !widget.canAct()) {
      return;
    }
    final callback = widget.callback;
    final finish = widget.onCallbackFinished;
    final task = _task = WindowSelectionTask(context);
    setState(() => isLoading = true);
    try {
      await task.run((operation) async {
        operation.checkActive();
        await invokeJsCallbackToCompletion(callback, []);
      });
      if (mounted && task.canPresent) finish?.call();
    } catch (error, stack) {
      if (error is JsDisposedError || error is SelectionCancelled) return;
      Log.error('JS dialog callback', error, stack);
      task.presentationContext?.showMessage(message: error.toString());
    } finally {
      if (mounted && identical(_task, task)) {
        setState(() {
          _task = null;
          isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final child = isLoading
        ? Semantics(
            label: widget.text,
            child: ExcludeSemantics(
              child: CircularProgressIndicator(
                strokeWidth: 1.4,
              ).fixWidth(18).fixHeight(18),
            ),
          )
        : Text(widget.text);
    return switch (widget.style) {
      "filled" => FilledButton(
        onPressed: isLoading ? null : onClick,
        child: child,
      ),
      "danger" => FilledButton(
        onPressed: isLoading ? null : onClick,
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.all(context.colorScheme.error),
        ),
        child: child,
      ),
      _ => TextButton(onPressed: isLoading ? null : onClick, child: child),
    };
  }
}
