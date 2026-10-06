import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera_next/foundation/application_update_service.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/network/request_scope.dart';

import 'window_frame.dart';

class ApplicationUpdateScope extends InheritedWidget {
  const ApplicationUpdateScope({
    required this.service,
    required super.child,
    super.key,
  });

  final ApplicationUpdateService service;

  static ApplicationUpdateService of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ApplicationUpdateScope>()!
      .service;

  @override
  bool updateShouldNotify(ApplicationUpdateScope oldWidget) =>
      !identical(service, oldWidget.service);
}

/// One check and its optional dialog belong to the original page and window.
/// Closing joins HTTP cleanup, cancels delay, and removes only its own dialog.
class ApplicationUpdatePrompt {
  ApplicationUpdatePrompt({
    required BuildContext context,
    required this.service,
    RequestScope? parent,
    bool Function()? isActive,
  }) : _context = context,
       _navigator = Navigator.of(context, rootNavigator: true),
       _route = ModalRoute.of(context),
       _window = context.getInheritedWidgetOfExactType<WindowFrameController>(),
       _scope = RequestScope(parent: parent),
       _isActive = isActive;

  final ApplicationUpdateService service;
  final BuildContext _context;
  final NavigatorState _navigator;
  final ModalRoute<dynamic>? _route;
  final WindowFrameController? _window;
  final RequestScope _scope;
  final bool Function()? _isActive;
  DialogRoute<void>? _dialog;
  Future<void>? _dialogRemoval;
  Future<void>? _checking;

  bool get _active =>
      !_scope.isCancelled &&
      _context.mounted &&
      _navigator.mounted &&
      _window?.isClosing != true &&
      (_route == null || _route.isCurrent) &&
      (_isActive?.call() ?? true) &&
      NavigationAdmission.allows(_context);

  Future<void> check({
    bool silent = false,
    Duration delay = Duration.zero,
    VoidCallback? onChecked,
  }) {
    final checking = _checking;
    if (checking != null) return checking;
    final done = Completer<void>();
    _checking = done.future;
    _window?.addCloseStartListener(cancel);
    _window?.addExitTask(closeAndWait);
    _window?.trackExitTask(done.future);
    if (_window?.isClosing == true) cancel();
    _check(
      silent: silent,
      delay: delay,
      onChecked: onChecked,
    ).then(done.complete, onError: done.completeError);
    return done.future;
  }

  Future<void> _check({
    required bool silent,
    required Duration delay,
    VoidCallback? onChecked,
  }) async {
    final context = _context;
    try {
      if (!context.mounted || !_active) return;
      final version = await service
          .check(scope: _scope)
          .whenComplete(() => onChecked?.call());
      if (!context.mounted || !_active) return;
      if (version == null) {
        if (!silent) {
          context.showMessage(message: 'No new version available'.tl);
        }
        return;
      }
      if (delay > Duration.zero) await _scope.wait(delay);
      if (!context.mounted || !_active) return;
      final dialog = DialogRoute<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('New version available'.tl),
          content: Text(
            'A new version @v is available. Do you want to update now?'
                .tlParams({'v': version}),
          ),
          actions: [
            TextButton(
              onPressed: () {
                if (!_scope.isCancelled &&
                    _dialog?.isCurrent == true &&
                    NavigationAdmission.allows(context)) {
                  Navigator.of(context).pop();
                }
              },
              child: Text('Cancel'.tl),
            ),
            TextButton(
              onPressed: () async {
                if (_scope.isCancelled ||
                    _dialog?.isCurrent != true ||
                    !NavigationAdmission.allows(context)) {
                  return;
                }
                Navigator.of(context).pop();
                try {
                  await launchUrlString(
                    'https://github.com/CyrilPeng/venera-next/releases',
                  );
                } catch (error, stack) {
                  Log.error('Open application release', error, stack);
                }
              },
              child: Text('Update'.tl),
            ),
          ],
        ),
      );
      _dialog = dialog;
      await Future.any<void>([_navigator.push(dialog), _scope.whenCancelled]);
    } on RequestCancelled {
      // Cancellation never presents a successful "no update" message.
    } catch (error, stack) {
      Log.error('Check application updates', error, stack);
      if (!silent && context.mounted && _active) {
        context.showMessage(message: 'Failed to check for updates'.tl);
      }
    } finally {
      try {
        await _removeDialog();
      } finally {
        _window?.removeCloseStartListener(cancel);
        _window?.removeExitTask(closeAndWait);
        _scope.dispose();
      }
    }
  }

  Future<void> _removeDialog() {
    final removing = _dialogRemoval;
    if (removing != null) return removing;
    final dialog = _dialog;
    if (dialog == null) return Future.value();
    final done = Completer<void>();
    _dialogRemoval = done.future;
    // Page disposal can occur while Navigator is locked. Defer only until the
    // current synchronous navigation/build completes, retaining route identity.
    scheduleMicrotask(() {
      try {
        if (_navigator.mounted &&
            dialog.isActive &&
            identical(dialog.navigator, _navigator)) {
          _navigator.removeRoute(dialog);
        }
        done.complete();
      } catch (error, stack) {
        done.completeError(error, stack);
      }
    });
    return done.future;
  }

  void cancel() => _scope.cancel();

  Future<void> closeAndWait() {
    cancel();
    return _checking ?? Future.value();
  }
}
