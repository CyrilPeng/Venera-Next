import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera_next/components/tv_navigation.dart';

/// Only the reading surface handles page keys; menus retain normal traversal.
class TvReaderInput extends StatefulWidget {
  const TvReaderInput({
    super.key,
    required this.menuOpen,
    required this.onToggleMenu,
    required this.onReadKey,
    required this.onCancelReadKeys,
    required this.onExit,
    required this.child,
    this.contentInteractive = false,
  });

  final bool menuOpen;
  final bool contentInteractive;
  final VoidCallback onToggleMenu;
  final ValueChanged<KeyEvent> onReadKey;
  final VoidCallback onCancelReadKeys;
  final Future<void> Function() onExit;
  final Widget child;

  @override
  State<TvReaderInput> createState() => _TvReaderInputState();
}

class _TvReaderInputState extends State<TvReaderInput>
    with WidgetsBindingObserver {
  final _reading = FocusNode(
    debugLabel: 'TV reading surface',
    skipTraversal: true,
  );
  final _scope = FocusScopeNode(debugLabel: 'TV reader');
  bool _foreground = true;
  bool _active = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _active = TvNavigation.enabledOf(context);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reading.addListener(_focusChanged);
  }

  void _focusChanged() {
    if (_active && !_reading.hasPrimaryFocus) widget.onCancelReadKeys();
  }

  @override
  void didUpdateWidget(TvReaderInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_active || oldWidget.menuOpen == widget.menuOpen) return;
    widget.onCancelReadKeys();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !TvNavigation.enabledOf(context) ||
          !_foreground ||
          ModalRoute.of(context)?.isCurrent == false) {
        return;
      }
      if (widget.menuOpen) {
        _scope.nextFocus();
      } else {
        _reading.requestFocus();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_active && !_foreground) widget.onCancelReadKeys();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_active) widget.onCancelReadKeys();
    _reading.dispose();
    _scope.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    final key = event.logicalKey;
    final back = const [
      LogicalKeyboardKey.escape,
      LogicalKeyboardKey.goBack,
      LogicalKeyboardKey.gameButtonB,
    ].contains(key);
    final activate = const [
      LogicalKeyboardKey.select,
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.numpadEnter,
      LogicalKeyboardKey.gameButtonA,
    ].contains(key);
    final direction = const [
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
    ].contains(key);
    if (!back && !activate && !direction) return KeyEventResult.ignored;
    if (!_foreground) return KeyEventResult.handled;
    if (back) {
      if (event is KeyDownEvent) {
        widget.onCancelReadKeys();
        if (widget.menuOpen) {
          widget.onToggleMenu();
        } else {
          unawaited(widget.onExit());
        }
      }
      return KeyEventResult.handled;
    }
    if (widget.menuOpen || !_reading.hasPrimaryFocus) {
      return KeyEventResult.ignored;
    }
    if (activate) {
      if (event is KeyDownEvent) widget.onToggleMenu();
      return KeyEventResult.handled;
    }
    if (widget.contentInteractive) return KeyEventResult.ignored;
    widget.onReadKey(event);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    if (!TvNavigation.enabledOf(context)) return widget.child;
    return FocusScope(
      node: _scope,
      child: Focus(
        focusNode: _reading,
        autofocus: true,
        onKeyEvent: _onKey,
        child: widget.child,
      ),
    );
  }
}
