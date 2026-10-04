import 'dart:async';
import 'package:flutter/material.dart';
import 'package:venera_next/network/request_scope.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'reader_controller.dart';

/// Owns the view lifetime of a content attempt, independent of ReaderState.
class ReaderImages extends StatefulWidget {
  const ReaderImages({
    super.key,
    required this.controller,
    this.imageWork,
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
  final ImageWork? imageWork;
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
  VoidCallback? _unsubscribeResume;

  void _listenForResume() {
    final owner = widget.imageWork;
    _unsubscribeResume = owner?.addResumeListener(() {
      if (!mounted ||
          !identical(widget.imageWork, owner) ||
          !_attempt.waitingForImageWork) {
        return;
      }
      setState(_begin);
    });
  }

  void _begin() {
    widget.onLoading();
    _attempt = widget.controller.beginContentLoad();
  }

  @override
  void initState() {
    super.initState();
    _begin();
    _listenForResume();
  }

  @override
  void didUpdateWidget(covariant ReaderImages oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller) ||
        !identical(oldWidget.imageWork, widget.imageWork)) {
      _unsubscribeResume?.call();
      oldWidget.controller.cancelContentLoad(_attempt);
      _begin();
      _listenForResume();
    }
  }

  @override
  void dispose() {
    _unsubscribeResume?.call();
    widget.controller.cancelContentLoad(_attempt);
    super.dispose();
  }

  Future<void> _load() async {
    final attempt = _attempt;
    final inputs = widget;
    bool isCurrent() =>
        mounted &&
        identical(_attempt, attempt) &&
        identical(widget.controller, inputs.controller) &&
        identical(widget.imageWork, inputs.imageWork);
    final result = await inputs.controller.loadContent(
      attempt,
      beforeLoad: () => inputs.beforeLoad(attempt.scope),
      loadImages: inputs.loadImages,
      prepareMode: inputs.prepareMode,
      imageWork: inputs.imageWork,
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
    if (_attempt.waitingForImageWork) {
      return const Center(child: CircularProgressIndicator());
    }
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
