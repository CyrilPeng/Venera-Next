import 'dart:async';
import 'package:flutter/material.dart';
import 'package:venera_next/network/request_scope.dart';
import 'reader_controller.dart';

/// Owns the view lifetime of a content attempt, independent of ReaderState.
class ReaderImages extends StatefulWidget {
  const ReaderImages({
    super.key,
    required this.controller,
    required this.beforeLoad,
    required this.loadImages,
    required this.prepareMode,
    required this.onLoading,
    required this.onCommitted,
    required this.onReady,
    required this.onSettled,
    required this.contentBuilder,
    required this.errorBuilder,
  });

  final ReaderController controller;
  final Future<void> Function(RequestScope) beforeLoad;
  final Future<List<String>> Function(RequestScope) loadImages;
  final Future<void> Function() prepareMode;
  final VoidCallback onLoading;
  final VoidCallback onCommitted;
  final VoidCallback onReady;
  final VoidCallback onSettled;
  final Widget Function(BuildContext, ReaderContentState) contentBuilder;
  final Widget Function(BuildContext, String, VoidCallback) errorBuilder;

  @override
  State<ReaderImages> createState() => _ReaderImagesState();
}

class _ReaderImagesState extends State<ReaderImages> {
  late ReaderContentLoad _attempt;

  void _begin() {
    widget.onLoading();
    _attempt = widget.controller.beginContentLoad();
  }

  @override
  void initState() {
    super.initState();
    _begin();
  }

  @override
  void didUpdateWidget(covariant ReaderImages oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.cancelContentLoad(_attempt);
      _begin();
    }
  }

  @override
  void dispose() {
    widget.controller.cancelContentLoad(_attempt);
    super.dispose();
  }

  Future<void> _load() async {
    final attempt = _attempt;
    final inputs = widget;
    bool isCurrent() =>
        mounted &&
        identical(_attempt, attempt) &&
        identical(widget.controller, inputs.controller);
    final result = await inputs.controller.loadContent(
      attempt,
      beforeLoad: () => inputs.beforeLoad(attempt.scope),
      loadImages: inputs.loadImages,
      prepareMode: inputs.prepareMode,
    );
    if (!isCurrent() || result == ReaderContentLoadResult.ignored) return;
    if (result == ReaderContentLoadResult.ready) {
      widget.onCommitted();
      scheduleMicrotask(() {
        if (isCurrent()) widget.onReady();
      });
    }
    setState(() {});
    widget.onSettled();
  }

  @override
  Widget build(BuildContext context) {
    final content = widget.controller.content;
    if (content.isLoading) {
      unawaited(_load());
      return const Center(child: CircularProgressIndicator());
    }
    if (content.error case final String error) {
      final attempt = _attempt;
      return widget.errorBuilder(context, error, () {
        if (mounted && identical(_attempt, attempt)) setState(_begin);
      });
    }
    return widget.contentBuilder(context, content);
  }
}
